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
        case processing
    }

    struct Tracks: Equatable {
        var microphone: URL
        /// nil when system audio couldn't be captured, so "Others" can't be heard.
        var systemAudio: URL?
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

    private let preferences: Preferences
    private let transcriber: Transcriber
    private let recorder = MeetingRecorder()
    private let notifier = MeetingNotifier()
    private var ticker: Timer?
    /// Keeps the Mac from idle-sleeping from Start until the transcript is written.
    private var activity: NSObjectProtocol?

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    init(preferences: Preferences, transcriber: Transcriber) {
        self.preferences = preferences
        self.transcriber = transcriber
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .preparing, .processing: break
        }
    }

    func start() {
        guard Self.isSupported, phase == .idle else { return }
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
            tracks = Tracks(microphone: Self.trackURL(base, "mic"))
            try recorder.startMicrophone(writingTo: tracks.microphone, preferredDeviceID: preferences.microphoneID)
        } catch {
            Log.info("meeting recorder failed to start: \(error)")
            lastError = "Мікрофон: \(error.localizedDescription)"
            phase = .idle
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
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording a meeting"
        )
        phase = .recording(startedAt: startedAt, tracks: tracks)
        elapsedSeconds = 0

        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .recording(let startedAt, _) = self.phase else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func stop() {
        guard case .recording(let startedAt, let tracks) = phase else { return }
        ticker?.invalidate()
        ticker = nil
        recorder.stop()
        othersWarning = nil
        let duration = Date().timeIntervalSince(startedAt)
        Log.info(String(format: "meeting recording stopped: %.0f s", duration))
        phase = .processing

        Task {
            defer {
                phase = .idle
                if let activity { ProcessInfo.processInfo.endActivity(activity) }
                activity = nil
            }
            do {
                let file = try await transcribe(tracks, startedAt: startedAt, duration: duration)
                Log.info("meeting transcript written: \(file.path)")
                notifier.transcriptReady(file)
            } catch {
                // The audio stays in Application Support so nothing is lost.
                Log.info("meeting processing failed: \(error)")
                lastError = "Зустріч не розшифровано: \(error.localizedDescription)"
                notifier.failed(error.localizedDescription)
            }
        }
    }

    private func transcribe(_ tracks: Tracks, startedAt: Date, duration: TimeInterval) async throws -> URL {
        guard await transcriber.waitUntilLoaded() else { throw TranscriberError.modelNotLoaded }
        let language = preferences.language.whisperCode
        let me = try await transcriber.transcribeFile(at: tracks.microphone, language: language)
        var others: [TranscriptSegment] = []
        if let systemAudio = tracks.systemAudio {
            do {
                others = try await transcriber.transcribeFile(at: systemAudio, language: language).segments
            } catch {
                // Keep the user's own words rather than losing the whole meeting.
                Log.info("system audio transcription failed, saving Me only: \(error)")
            }
        }
        let metadata = MeetingMetadata(
            startDate: startedAt, duration: duration, app: Self.manualSource,
            language: me.language, notes: .none, audio: .kept
        )
        let markdown = MeetingDocument.markdown(me: me.segments, others: others, metadata: metadata)

        let folder = preferences.meetingsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = Self.unusedURL(in: folder, named: MeetingDocument.fileName(startDate: startedAt, app: Self.manualSource))
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

    /// Appends " 2", " 3"… so a second meeting in the same minute never overwrites the first.
    private static func unusedURL(in folder: URL, named name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index).md")
            index += 1
        }
        return candidate
    }
}
