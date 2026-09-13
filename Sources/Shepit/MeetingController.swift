import AppKit
import Combine
import ShepitCore

/// Manual meeting recording: microphone and system audio to disk while recording,
/// then a two-track transcript file after Stop.
@MainActor
final class MeetingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting on the system audio explanation or permission dialog.
        case preparing
        case recording(id: String, startedAt: Date, tracks: RecordingStore.Tracks)
    }

    /// A recording waiting for, or going through, transcription.
    private struct Job {
        var id: String
        /// The meeting file to rewrite when re-transcribing; nil writes a new one.
        var target: URL?
        /// The microphone track's transcript, kept so a paused meeting doesn't transcribe it twice.
        var me: (segments: [TranscriptSegment], language: String)?
    }

    /// System audio capture uses Core Audio process taps, which arrived in macOS 14.2.
    static let isSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
    )
    static let unsupportedReason = "Запис зустрічей потребує macOS 14.2 або новішої."
    /// Source name for recordings started by hand rather than by a detected call app.
    static let manualSource = "Manual"
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    @Published private(set) var phase = Phase.idle
    /// Whole seconds since the meeting recording started, for the menu bar timer.
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var lastError: String?
    /// Set while a recording runs without system audio.
    @Published private(set) var othersWarning: String?
    /// Set while "Still recording?" waits for an answer.
    @Published private(set) var stillRecordingPrompt: MeetingSession.PromptReason?
    /// The call-detection offer currently on screen.
    @Published private(set) var offer: Offer?
    /// Stopped meetings waiting for or going through transcription.
    @Published private(set) var processingCount = 0
    /// Every recording whose audio is still on disk.
    @Published private(set) var recordings: [RecordingManifest] = []

    enum Offer: Equatable {
        /// `app` began using the microphone: record the call?
        case record(app: String)
        /// `app` released the microphone while recording: stop?
        case stop(app: String)
    }

    private let preferences: Preferences
    private let transcriber: Transcriber
    private let recorder: MeetingRecorder
    private let notifier = MeetingNotifier()
    private var session = MeetingSession()
    private var queue = MeetingProcessingQueue<String>()
    private var jobs: [String: Job] = [:]
    /// Deletes expired audio now and then; the sweep is cheap, so hourly keeps it close to "daily" across sleeps.
    private var sweeper: Timer?
    private var processingTask: Task<Void, Never>?
    /// `CallDetector` on macOS 14.2+; typed loosely because stored properties can't be availability-gated.
    private var callDetector: AnyObject?
    /// Name written to the meeting file for the recording being made: the detected call app or `manualSource`.
    private var source = MeetingController.manualSource
    private var subscriptions: Set<AnyCancellable> = []
    /// Push-to-talk dictations made during the current recording; their "Me" speech stays out of the transcript.
    private var dictation: [DictationInterval] = []
    private var dictationStartedAt: Date?
    private var ticker: Timer?
    /// Keeps the Mac from idle-sleeping while recording and while any meeting waits for its transcript.
    private var activity: NSObjectProtocol?

    /// Opens a finished meeting, e.g. when its "Transcript ready" notification is clicked.
    var onOpenMeeting: ((URL) -> Void)? {
        get { notifier.onOpenMeeting }
        set { notifier.onOpenMeeting = newValue }
    }

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    var isProcessing: Bool { processingCount > 0 }

    /// Recordings without a transcript that aren't recording or queued: unfinished after a quit or crash, or failed.
    var untranscribed: [RecordingManifest] {
        recordings.filter { ($0.isUnfinished || $0.status == .failed) && !isBusy($0.id) }
    }

    /// Unfinished recordings left by a quit or crash, waiting for the user to finish them.
    var unfinished: [RecordingManifest] { untranscribed.filter(\.isUnfinished) }

    /// Queued for transcription or still being recorded.
    func isBusy(_ id: String) -> Bool {
        if jobs[id] != nil { return true }
        if case .recording(let recording, _, _) = phase { return recording == id }
        return false
    }

    init(preferences: Preferences, transcriber: Transcriber, microphone: SharedMicrophone) {
        self.preferences = preferences
        self.transcriber = transcriber
        recorder = MeetingRecorder(microphone: microphone)
        notifier.onStillRecordingAnswer = { [weak self] keepRecording in
            MainActor.assumeIsolated { self?.answerStillRecording(keepRecording) }
        }
        notifier.onOfferAnswer = { [weak self] accepted in
            MainActor.assumeIsolated { accepted ? self?.acceptOffer() : self?.dismissOffer() }
        }
        notifier.onRecoveryAnswer = { [weak self] accepted in
            MainActor.assumeIsolated { if accepted { self?.finishUnfinished() } }
        }
        if #available(macOS 14.2, *) { startCallDetection() }
        guard Self.isSupported else { return }
        recoverUnfinished()
        sweepAudio()
        let sweeper = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepAudio() }
        }
        RunLoop.main.add(sweeper, forMode: .common)
        self.sweeper = sweeper
    }

    @available(macOS 14.2, *)
    private func startCallDetection() {
        let detector = CallDetector(apps: preferences.callApps)
        detector.onEvents = { [weak self] events in
            for event in events { self?.send(event) }
        }
        preferences.$callApps
            .sink { [weak detector] apps in detector?.apps = apps }
            .store(in: &subscriptions)
        callDetector = detector
        // Offers are notifications, so ask before the first call rather than lose that offer to the prompt.
        notifier.requestAuthorization()
        detector.start()
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .preparing: break
        }
    }

    func start() {
        guard Self.isSupported, phase == .idle else { return }
        send(.start)
    }

    func stop() {
        send(.stop)
    }

    func answerStillRecording(_ keepRecording: Bool) {
        send(.stillRecording(keepRecording))
    }

    /// Records the offered call, or stops a recording whose call app released the microphone.
    func acceptOffer() {
        send(.offerAccepted)
    }

    func dismissOffer() {
        send(.offerDismissed)
    }

    /// Dictation reports every push-to-talk recording, whether or not a meeting is running.
    func dictationStarted() {
        dictationStartedAt = Date()
    }

    func dictationEnded() {
        guard case .recording(_, let startedAt, let tracks) = phase else {
            dictationStartedAt = nil
            return
        }
        closeDictation(meetingStartedAt: startedAt, endingAt: Date().timeIntervalSince(startedAt), tracks: tracks)
    }

    /// Adds the dictation in progress, if any, to this meeting's intervals and saves them.
    private func closeDictation(meetingStartedAt startedAt: Date, endingAt end: TimeInterval, tracks: RecordingStore.Tracks) {
        defer { dictationStartedAt = nil }
        guard let began = dictationStartedAt else { return }
        // A dictation already running when the meeting started counts from the meeting's first second.
        dictation.append(DictationInterval(start: max(0, began.timeIntervalSince(startedAt)), end: end))
        saveDictation(to: tracks.dictation)
    }

    private func saveDictation(to url: URL) {
        do {
            try JSONEncoder().encode(dictation).write(to: url, options: .atomic)
        } catch {
            Log.info("dictation intervals not saved: \(error)")
        }
    }

    /// Monotonic clock for the session; unaffected by the user changing the system time.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func send(_ event: MeetingSession.Event) {
        for command in session.handle(event, at: Self.now) {
            switch command {
            case .startRecording(let app):
                source = app ?? Self.manualSource
                startRecording()
            case .stopRecording:
                finishRecording()
            case .askStillRecording(let reason):
                Log.info("asking still recording? reason=\(reason)")
                stillRecordingPrompt = reason
                notifier.askStillRecording(reason)
            case .dismissStillRecording:
                // Clears both places, whichever one the user answered in.
                stillRecordingPrompt = nil
                notifier.dismissStillRecording()
            case .offerToRecord(let app):
                offer = .record(app: app)
                notifier.offerToRecord(app: app)
            case .offerToStop(let app):
                offer = .stop(app: app)
                notifier.offerToStop(app: app)
            case .dismissOffer:
                offer = nil
                notifier.dismissOffer()
            }
        }
    }

    private func startRecording() {
        phase = .preparing
        Task {
            let skipOthersReason = await prepareSystemAudio()
            beginRecording(skipOthersReason: skipOthersReason)
        }
    }

    /// Explains and requests the System Audio Recording permission the first time; returns
    /// why system audio won't be captured, or nil to capture it.
    private func prepareSystemAudio() async -> String? {
        let denied = "Інших не чути — немає дозволу на запис системного звуку."
        switch SystemAudioPermission.status {
        case .authorized, .unknown:
            return nil
        case .denied:
            return denied
        case .undetermined:
            guard explainSystemAudio() else { return "Інших не чути — обрано запис лише мікрофона." }
            return await SystemAudioPermission.request() ? nil : denied
        }
    }

    private func explainSystemAudio() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Shepit запише голоси співрозмовників"
        alert.informativeText = """
            Щоб у транскрипті були інші учасники дзвінка, Shepit записує звук, який грає Mac. \
            Далі macOS попросить дозвіл «Запис системного звуку». Запис і розпізнавання лишаються на цьому Mac.
            """
        alert.addButton(withTitle: "Продовжити")
        alert.addButton(withTitle: "Лише мікрофон")
        // Shepit has no Dock icon, so bring it forward or the alert opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func beginRecording(skipOthersReason: String?) {
        let startedAt = Date()
        let id = RecordingStore.id(for: startedAt)
        var tracks: RecordingStore.Tracks
        do {
            tracks = try RecordingStore.tracks(id)
            try recorder.startMicrophone(writingTo: tracks.microphone, preferredDeviceID: preferences.microphoneID)
        } catch {
            Log.info("meeting recorder failed to start: \(error)")
            lastError = "Мікрофон: \(error.localizedDescription)"
            phase = .idle
            send(.failedToStart)
            return
        }

        othersWarning = skipOthersReason
        if skipOthersReason == nil, #available(macOS 14.2, *) {
            do {
                let url = try RecordingStore.systemAudioURL(id)
                try recorder.startSystemAudio(writingTo: url)
                tracks.systemAudio = url
            } catch {
                Log.info("system audio failed to start: \(error)")
                othersWarning = "Інших не чути: \(error.localizedDescription)"
            }
        }

        notifier.requestAuthorization()
        if let othersWarning { notifier.othersUnavailable(othersWarning) }
        Log.info("meeting recording started: \(tracks.microphone.path), system audio: \(tracks.systemAudio?.path ?? "none")")
        lastError = nil
        // Saved before anything else can fail, so a crash from here on leaves a recording to finish.
        RecordingStore.save(RecordingManifest(id: id, startDate: startedAt, app: source, status: .recording))
        phase = .recording(id: id, startedAt: startedAt, tracks: tracks)
        reloadRecordings()
        updateActivity()
        sendToQueue(.recordingStarted)
        elapsedSeconds = 0
        dictation = []
        // Written up front, so a recording without dictation is told apart from one whose intervals were lost.
        saveDictation(to: tracks.dictation)
        send(.started)

        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .recording(_, let startedAt, _) = self.phase else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
                self.send(.level(decibels: self.recorder.takeLoudestLevel()))
                self.send(.tick)
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func finishRecording() {
        guard case .recording(let id, let startedAt, let tracks) = phase else { return }
        ticker?.invalidate()
        ticker = nil
        recorder.stop()
        othersWarning = nil
        let duration = Date().timeIntervalSince(startedAt)
        // Still dictating when the meeting stopped: that dictation runs to the end.
        closeDictation(meetingStartedAt: startedAt, endingAt: duration, tracks: tracks)
        Log.info(String(format: "meeting recording stopped: %.0f s", duration))
        RecordingStore.save(RecordingManifest(
            id: id, startDate: startedAt, duration: duration, app: source, status: .stopped
        ))
        phase = .idle
        enqueue(Job(id: id))
        sendToQueue(.recordingStopped)
    }

    // MARK: Processing

    private func enqueue(_ job: Job) {
        guard !isBusy(job.id) else { return }
        jobs[job.id] = job
        sendToQueue(.enqueued(job.id))
    }

    private func sendToQueue(_ event: MeetingProcessingQueue<String>.Event) {
        for command in queue.handle(event) {
            switch command {
            case .run(let id): process(id)
            case .interrupt(let id):
                Log.info("meeting processing paused for a new recording: \(id)")
                processingTask?.cancel()
            }
        }
        processingCount = queue.count
        updateActivity()
        reloadRecordings()
    }

    private func updateActivity() {
        let needed = isRecording || queue.hasWork
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording or transcribing a meeting"
            )
        } else if !needed, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    private func process(_ id: String) {
        processingTask = Task {
            do {
                let file = try await transcribe(id)
                let target = jobs.removeValue(forKey: id)?.target
                updateManifest(id) { $0.status = .transcribed; $0.error = nil }
                Log.info("meeting transcript written: \(file.path)")
                if target == nil { notifier.transcriptReady(file) }
                sendToQueue(.finished(id))
            } catch where Task.isCancelled {
                sendToQueue(.interrupted(id))
            } catch {
                // The audio stays in Application Support so nothing is lost.
                let job = jobs.removeValue(forKey: id)
                // A failed re-transcription leaves the earlier transcript, and its audio's status, as they were.
                if job?.target == nil {
                    updateManifest(id) { $0.status = .failed; $0.error = error.localizedDescription }
                }
                Log.info("meeting processing failed: \(error)")
                lastError = "Зустріч не розшифровано: \(error.localizedDescription)"
                notifier.failed(error.localizedDescription)
                sendToQueue(.finished(id))
            }
        }
    }

    private func transcribe(_ id: String) async throws -> URL {
        guard let job = jobs[id], let manifest = RecordingStore.all().first(where: { $0.id == id }) else {
            throw RecordingError.missing
        }
        guard RecordingStore.hasAudio(id) else { throw RecordingError.missing }
        guard await transcriber.waitUntilLoaded() else { throw TranscriberError.modelNotLoaded }
        try Task.checkCancellation()
        let tracks = try RecordingStore.tracks(id)
        let language = preferences.meetingLanguage.whisperCode
        let me: (segments: [TranscriptSegment], language: String)
        if let done = job.me {
            me = done
        } else {
            me = try await transcriber.transcribeFile(at: tracks.microphone, language: language)
            try Task.checkCancellation()
            jobs[id]?.me = me
        }
        var others: [TranscriptSegment] = []
        if let systemAudio = tracks.systemAudio {
            do {
                others = try await transcriber.transcribeFile(at: systemAudio, language: language).segments
                try Task.checkCancellation()
            } catch where Task.isCancelled {
                throw CancellationError()
            } catch {
                // Keep the user's own words rather than losing the whole meeting.
                Log.info("system audio transcription failed, saving Me only: \(error)")
            }
        }
        let metadata = MeetingMetadata(
            startDate: manifest.startDate,
            duration: manifest.duration ?? RecordingStore.recordedDuration(id) ?? 0,
            app: manifest.app, language: me.language, notes: .none, audio: .kept, recording: id
        )
        var markdown = MeetingDocument.markdown(
            me: me.segments, others: others, dictation: RecordingStore.dictation(id), metadata: metadata
        )

        if let target = job.target, let existing = try? String(contentsOf: target, encoding: .utf8) {
            // Re-transcribing replaces the transcript but keeps the name the user gave the meeting.
            if let title = MeetingDocument.title(of: existing) { markdown = MeetingDocument.retitled(markdown, to: title) }
            // Written in place so the file keeps its creation date.
            try markdown.write(to: target, atomically: false, encoding: .utf8)
            return target
        }
        let folder = preferences.meetingsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try Self.unusedURL(
            in: folder, named: MeetingDocument.fileName(startDate: manifest.startDate, app: manifest.app)
        )
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: Recordings on disk

    enum RecordingError: LocalizedError {
        case missing

        var errorDescription: String? { "аудіо цього запису вже немає" }
    }

    /// The recording a meeting file was transcribed from, while its audio is still on disk.
    func recordingID(ofMeeting markdown: String) -> String? {
        guard let id = MeetingDocument.frontmatterValue("recording", in: markdown), RecordingStore.hasAudio(id) else {
            return nil
        }
        return id
    }

    /// Transcribes a meeting's audio again into the same file, e.g. after changing the meeting language.
    func retranscribe(meetingFile: URL) {
        guard let markdown = try? String(contentsOf: meetingFile, encoding: .utf8),
              let id = recordingID(ofMeeting: markdown)
        else { return }
        enqueue(Job(id: id, target: meetingFile))
    }

    /// Transcribes an unfinished or failed recording into a new meeting file.
    func transcribe(recording id: String) {
        guard RecordingStore.hasAudio(id) else { return }
        enqueue(Job(id: id))
    }

    /// Deletes a recording that has no transcript; the user decided it isn't worth keeping.
    func deleteRecording(_ id: String) {
        guard !isBusy(id) else { return }
        RecordingStore.delete(id)
        Log.info("recording deleted by user: \(id)")
        reloadRecordings()
    }

    func finishUnfinished() {
        notifier.dismissRecovery()
        for recording in unfinished { enqueue(Job(id: recording.id)) }
    }

    /// Recordings still marked recording or stopped at launch were cut off by a quit or crash.
    private func recoverUnfinished() {
        for recording in RecordingStore.all() where recording.status == .recording {
            // The tracks were written incrementally, so what reached the disk is the recording.
            updateManifest(recording.id) {
                $0.status = .stopped
                $0.duration = RecordingStore.recordedDuration(recording.id)
            }
        }
        reloadRecordings()
        let count = unfinished.count
        guard count > 0 else { return }
        Log.info("unfinished recordings at launch: \(count)")
        notifier.requestAuthorization()
        notifier.offerRecovery(count: count)
    }

    /// Deletes the audio of meetings transcribed long enough ago and marks it deleted in their files.
    func sweepAudio() {
        let expired = AudioRetention.expired(RecordingStore.all(), now: Date()).filter { !isBusy($0.id) }
        guard !expired.isEmpty else { return }
        let folder = preferences.meetingsFolder
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url, $0) } }
        for recording in expired {
            do {
                for (url, markdown) in files where MeetingDocument.frontmatterValue("recording", in: markdown) == recording.id {
                    let updated = MeetingDocument.settingFrontmatter("audio", to: MeetingMetadata.AudioStatus.deleted.rawValue, in: markdown)
                    try updated.write(to: url, atomically: false, encoding: .utf8)
                }
            } catch {
                // Try again next sweep rather than leave a file claiming audio that's gone.
                Log.info("audio kept, meeting file not updated for \(recording.id): \(error)")
                continue
            }
            RecordingStore.delete(recording.id)
            Log.info("audio deleted after retention period: \(recording.id)")
        }
        reloadRecordings()
    }

    private func updateManifest(_ id: String, _ change: (inout RecordingManifest) -> Void) {
        guard var manifest = RecordingStore.all().first(where: { $0.id == id }) else { return }
        change(&manifest)
        RecordingStore.save(manifest)
    }

    private func reloadRecordings() {
        let loaded = RecordingStore.all()
        if loaded != recordings { recordings = loaded }
    }

    /// Appends " 2", " 3"… so a second meeting in the same minute never overwrites the first.
    private static func unusedURL(in folder: URL, named name: String) throws -> URL {
        let existing = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        return folder.appendingPathComponent(MeetingDocument.unusedFileName(name, existing: existing))
    }
}
