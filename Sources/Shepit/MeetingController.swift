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
        case recording(startedAt: Date, tracks: Tracks)
    }

    /// A stopped meeting waiting for, or going through, transcription.
    private struct StoppedMeeting {
        var tracks: Tracks
        var dictation: [DictationInterval]
        var source: String
        var startedAt: Date
        var duration: TimeInterval
        /// The microphone track's transcript, kept so a paused meeting doesn't transcribe it twice.
        var me: (segments: [TranscriptSegment], language: String)?
    }

    struct Tracks: Equatable {
        var microphone: URL
        /// nil when system audio couldn't be captured, so "Others" can't be heard.
        var systemAudio: URL?
        /// JSON list of dictation intervals, saved next to the audio so they outlive a crash.
        var dictation: URL
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
    private var queue = MeetingProcessingQueue<UUID>()
    private var stoppedMeetings: [UUID: StoppedMeeting] = [:]
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
        if #available(macOS 14.2, *) { startCallDetection() }
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
        guard case .recording(let startedAt, let tracks) = phase else {
            dictationStartedAt = nil
            return
        }
        closeDictation(meetingStartedAt: startedAt, endingAt: Date().timeIntervalSince(startedAt), tracks: tracks)
    }

    /// Adds the dictation in progress, if any, to this meeting's intervals and saves them.
    private func closeDictation(meetingStartedAt startedAt: Date, endingAt end: TimeInterval, tracks: Tracks) {
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
        var tracks: Tracks
        let base: URL
        do {
            base = try Self.recordingBaseURL(for: startedAt)
            tracks = Tracks(microphone: Self.trackURL(base, "mic"), dictation: Self.sidecarURL(base, "dictation"))
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
            let url = Self.trackURL(base, "system")
            do {
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
        phase = .recording(startedAt: startedAt, tracks: tracks)
        updateActivity()
        sendToQueue(.recordingStarted)
        elapsedSeconds = 0
        dictation = []
        // Written up front, so a recording without dictation is told apart from one whose intervals were lost.
        saveDictation(to: tracks.dictation)
        send(.started)

        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .recording(let startedAt, _) = self.phase else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
                self.send(.level(decibels: self.recorder.takeLoudestLevel()))
                self.send(.tick)
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func finishRecording() {
        guard case .recording(let startedAt, let tracks) = phase else { return }
        ticker?.invalidate()
        ticker = nil
        recorder.stop()
        othersWarning = nil
        let duration = Date().timeIntervalSince(startedAt)
        // Still dictating when the meeting stopped: that dictation runs to the end.
        closeDictation(meetingStartedAt: startedAt, endingAt: duration, tracks: tracks)
        Log.info(String(format: "meeting recording stopped: %.0f s", duration))
        phase = .idle

        let id = UUID()
        stoppedMeetings[id] = StoppedMeeting(
            tracks: tracks, dictation: dictation, source: source, startedAt: startedAt, duration: duration
        )
        sendToQueue(.enqueued(id))
        sendToQueue(.recordingStopped)
    }

    private func sendToQueue(_ event: MeetingProcessingQueue<UUID>.Event) {
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

    private func process(_ id: UUID) {
        processingTask = Task {
            do {
                let file = try await transcribe(id)
                stoppedMeetings[id] = nil
                Log.info("meeting transcript written: \(file.path)")
                notifier.transcriptReady(file)
                sendToQueue(.finished(id))
            } catch where Task.isCancelled {
                sendToQueue(.interrupted(id))
            } catch {
                // The audio stays in Application Support so nothing is lost.
                stoppedMeetings[id] = nil
                Log.info("meeting processing failed: \(error)")
                lastError = "Зустріч не розшифровано: \(error.localizedDescription)"
                notifier.failed(error.localizedDescription)
                sendToQueue(.finished(id))
            }
        }
    }

    private func transcribe(_ id: UUID) async throws -> URL {
        guard let meeting = stoppedMeetings[id] else { throw CancellationError() }
        guard await transcriber.waitUntilLoaded() else { throw TranscriberError.modelNotLoaded }
        try Task.checkCancellation()
        let language = preferences.meetingLanguage.whisperCode
        let me: (segments: [TranscriptSegment], language: String)
        if let done = meeting.me {
            me = done
        } else {
            me = try await transcriber.transcribeFile(at: meeting.tracks.microphone, language: language)
            try Task.checkCancellation()
            stoppedMeetings[id]?.me = me
        }
        var others: [TranscriptSegment] = []
        if let systemAudio = meeting.tracks.systemAudio {
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
            startDate: meeting.startedAt, duration: meeting.duration, app: meeting.source,
            language: me.language, notes: .none, audio: .kept
        )
        let markdown = MeetingDocument.markdown(
            me: me.segments, others: others, dictation: meeting.dictation, metadata: metadata
        )

        let folder = preferences.meetingsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try Self.unusedURL(
            in: folder, named: MeetingDocument.fileName(startDate: meeting.startedAt, app: meeting.source)
        )
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Shared stem of a meeting's track files, e.g. `…/Recordings/2026-09-13 14-30-05`.
    private static func recordingBaseURL(for date: Date) throws -> URL {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Shepit/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return folder.appendingPathComponent(formatter.string(from: date))
    }

    private static func trackURL(_ base: URL, _ track: String) -> URL {
        base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) \(track).caf")
    }

    private static func sidecarURL(_ base: URL, _ name: String) -> URL {
        base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) \(name).json")
    }

    /// Appends " 2", " 3"… so a second meeting in the same minute never overwrites the first.
    private static func unusedURL(in folder: URL, named name: String) throws -> URL {
        let existing = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        return folder.appendingPathComponent(MeetingDocument.unusedFileName(name, existing: existing))
    }
}
