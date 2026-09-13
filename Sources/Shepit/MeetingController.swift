import AppKit
import Combine
import ShepitCore

/// Manual meeting recording: microphone to disk while recording, then a transcript file after Stop.
@MainActor
final class MeetingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date, audioURL: URL)
        case processing
    }

    /// System audio capture for meetings will use Core Audio process taps (macOS 14.2+),
    /// so the whole feature is gated on it from the first version.
    static let isSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
    )
    static let unsupportedReason = "Запис зустрічей потребує macOS 14.2 або новішої."
    /// Source name for recordings started by hand rather than by a detected call app.
    static let manualSource = "Manual"

    @Published private(set) var phase = Phase.idle
    /// Whole seconds since the meeting recording started, for the menu bar timer.
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var lastError: String?

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
        case .processing: break
        }
    }

    func start() {
        guard Self.isSupported, phase == .idle else { return }
        let startedAt = Date()
        let audioURL: URL
        do {
            audioURL = try Self.recordingURL(for: startedAt)
            try recorder.start(writingTo: audioURL, preferredDeviceID: preferences.microphoneID)
        } catch {
            Log.info("meeting recorder failed to start: \(error)")
            lastError = "Мікрофон: \(error.localizedDescription)"
            return
        }
        Log.info("meeting recording started: \(audioURL.path)")
        notifier.requestAuthorization()
        lastError = nil
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording a meeting"
        )
        phase = .recording(startedAt: startedAt, audioURL: audioURL)
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
        guard case .recording(let startedAt, let audioURL) = phase else { return }
        ticker?.invalidate()
        ticker = nil
        recorder.stop()
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
                let file = try await transcribe(audioURL, startedAt: startedAt, duration: duration)
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

    private func transcribe(_ audioURL: URL, startedAt: Date, duration: TimeInterval) async throws -> URL {
        guard await transcriber.waitUntilLoaded() else { throw TranscriberError.modelNotLoaded }
        let result = try await transcriber.transcribeFile(at: audioURL, language: preferences.language.whisperCode)
        let metadata = MeetingMetadata(
            startDate: startedAt, duration: duration, app: Self.manualSource,
            language: result.language, notes: .none, audio: .kept
        )
        let markdown = MeetingDocument.markdown(me: result.segments, metadata: metadata)

        let folder = preferences.meetingsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = Self.unusedURL(in: folder, named: MeetingDocument.fileName(startDate: startedAt, app: Self.manualSource))
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func recordingURL(for date: Date) throws -> URL {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Shepit/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return folder.appendingPathComponent("\(formatter.string(from: date)) mic.caf")
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
