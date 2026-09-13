import AppKit
import Combine
import AVFoundation
import SwiftUI
import ShepitCore

enum Status: Equatable {
    case loadingModel(String)
    case idle
    case recording
    case transcribing
    case success
    case failure(String)
    case error(String)

    var title: String {
        switch self {
        case .loadingModel(let detail): detail
        case .idle: "Готово"
        case .recording: "Слухаю…"
        case .transcribing: "Розпізнаю…"
        case .success: "Скопійовано"
        case .failure(let message): message.prefix(1).uppercased() + message.dropFirst()
        case .error(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .loadingModel: "arrow.down.circle"
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .success: "checkmark.circle"
        case .failure, .error: "exclamationmark.triangle"
        }
    }

    var isError: Bool {
        switch self {
        case .error, .failure: true
        default: false
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: Status = .loadingModel("Завантаження моделі…")
    @Published var lastText = ""
    @Published var hasAccessibility = TextInserter.isTrusted
    @Published private(set) var recordingStartedAt = Date()
    @Published private(set) var isHandsFree = false
    /// Whole seconds since recording started, for the menu bar timer capsule.
    @Published private(set) var elapsedSeconds = 0
    let preferences = Preferences()
    let microphones = Microphones()
    let meeting: MeetingController
    let meetingsWindow: MeetingsWindow
    var overlayModel: OverlayModel { overlay.model }

    private let microphone = SharedMicrophone()
    private let recorder: AudioRecorder
    private let transcriber = Transcriber()
    private let overlay = RecordingOverlay()
    private var pushToTalk = PushToTalk()
    private var keyboard: KeyboardTap?
    private var ticker: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var modelReady = false
    private var isTranscribing = false

    init() {
        recorder = AudioRecorder(microphone: microphone)
        meeting = MeetingController(preferences: preferences, transcriber: transcriber, microphone: microphone)
        meetingsWindow = MeetingsWindow(preferences: preferences, meeting: meeting)
        meeting.onOpenMeeting = { [weak self] file in
            MainActor.assumeIsolated { self?.meetingsWindow.show(selecting: file) }
        }
        keyboard = KeyboardTap(hotkey: preferences.hotkey) { [weak self] event, time in
            MainActor.assumeIsolated { self?.handle(event, at: time) ?? false }
        }
        keyboard?.onMeetingShortcut = { [weak self] in
            MainActor.assumeIsolated { self?.meeting.toggle() }
        }
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.overlay.push(level: level) }
        }
        overlay.onHide = { [weak self] in
            guard let self else { return }
            switch status {
            case .success, .failure: status = .idle
            default: break
            }
        }
        observePreferences()
        Task { await setUp() }
    }

    private func observePreferences() {
        preferences.$appearance
            .sink { NSApp.appearance = $0.nsAppearance }
            .store(in: &subscriptions)
        preferences.$hotkey
            .sink { [weak self] key in
                self?.keyboard?.hotkey = key
                self?.overlay.stopKeySymbol = key.symbol
            }
            .store(in: &subscriptions)
        preferences.$meetingShortcut
            .sink { [weak self] shortcut in
                self?.keyboard?.meetingShortcut = MeetingController.isSupported ? shortcut : .none
            }
            .store(in: &subscriptions)
        preferences.$handsFreeEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                // Takes effect from the next recording; never flip mode mid-recording.
                if !pushToTalk.isRecording { pushToTalk.handsFreeEnabled = enabled }
            }
            .store(in: &subscriptions)
    }

    func requestAccessibility() {
        TextInserter.promptForTrust()
    }

    private func setUp() async {
        Log.info("launch; accessibility trusted=\(TextInserter.isTrusted), microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        startKeyboardTapWhenTrusted()
        // Don't block model loading on the permission dialog.
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.info("microphone access granted=\(granted)")
        }

        do {
            Log.info("model load started")
            try await transcriber.load { [weak self] progress in
                Task { @MainActor in
                    guard self?.modelReady == false else { return }
                    self?.status = .loadingModel("Модель: \(Int(progress * 100))%")
                }
            }
            modelReady = true
            status = .idle
            Log.info("model ready")
        } catch {
            status = .error("Модель не завантажилась: \(error.localizedDescription)")
            Log.info("model load failed: \(error)")
        }
    }

    /// The event tap can only be created once Accessibility is granted, so keep retrying.
    private func startKeyboardTapWhenTrusted() {
        if !TextInserter.isTrusted { requestAccessibility() }
        Task {
            while keyboard?.start() == false {
                try? await Task.sleep(for: .seconds(1))
            }
            hasAccessibility = true
            Log.info("keyboard tap started")
        }
    }

    // MARK: - Push-to-talk

    /// Menu equivalent of the hotkey: release finishes a hold, a press finishes hands-free.
    func stopRecordingFromMenu() {
        let now = ProcessInfo.processInfo.systemUptime
        _ = handle(.keyUp, at: now)
        if pushToTalk.isRecording { _ = handle(.keyDown, at: now) }
    }

    func cancelRecordingFromMenu() {
        _ = handle(.escape, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Returns true when the key event should be swallowed.
    private func handle(_ event: PushToTalk.Event, at time: TimeInterval) -> Bool {
        guard modelReady, !isTranscribing else { return false }
        let wasRecording = pushToTalk.isRecording
        if !wasRecording { pushToTalk.handsFreeEnabled = preferences.handsFreeEnabled }
        for command in pushToTalk.handle(event, at: time) {
            // If the microphone failed, skip the rest of the batch (e.g. enter hands-free).
            guard execute(command) else { break }
        }
        return event == .escape && wasRecording
    }

    /// Returns false when the command failed and later commands must not run.
    private func execute(_ command: PushToTalk.Command) -> Bool {
        switch command {
        case .start: return startRecording()
        case .enterHandsFree:
            isHandsFree = true
            overlay.show(.recording(handsFree: true, startedAt: recordingStartedAt))
        case .finish: finishRecording()
        case .cancel, .discard: abortRecording()
        }
        return true
    }

    private func startRecording() -> Bool {
        do {
            try recorder.start(preferredDeviceID: preferences.microphoneID)
        } catch {
            pushToTalk = PushToTalk(handsFreeEnabled: preferences.handsFreeEnabled)
            overlay.hide()
            status = .error("Мікрофон: \(error.localizedDescription)")
            Log.info("recorder failed to start: \(error)")
            return false
        }
        meeting.dictationStarted()
        recordingStartedAt = Date()
        elapsedSeconds = 0
        isHandsFree = false
        status = .recording
        playSound("Tink")
        overlay.show(.recording(handsFree: false, startedAt: recordingStartedAt))
        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(self.recordingStartedAt))
                _ = self.handle(.tick, at: ProcessInfo.processInfo.systemUptime)
            }
        }
        // Common modes keep the hands-free limit ticking while menus are open.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        return true
    }

    private func playSound(_ name: String) {
        guard preferences.soundsEnabled else { return }
        NSSound(named: name)?.play()
    }

    private func abortRecording() {
        stopTicker()
        _ = recorder.stop()
        // Even cancelled dictation was spoken aloud, so it stays out of the meeting too.
        meeting.dictationEnded()
        overlay.hide()
        status = .idle
    }

    private func finishRecording() {
        stopTicker()
        let samples = recorder.stop()
        meeting.dictationEnded()
        playSound("Pop")

        isTranscribing = true
        status = .transcribing
        overlay.show(.transcribing)
        Task {
            defer { isTranscribing = false }
            do {
                let text = try await transcriber.transcribe(samples, language: preferences.language.whisperCode)
                guard !text.isEmpty else {
                    showFailure("нічого не розпізнано")
                    return
                }
                lastText = text
                TextInserter.insert(text)
                overlay.show(.success)
                status = .success
            } catch {
                Log.info("transcription failed: \(error)")
                showFailure("помилка розпізнавання")
            }
        }
    }

    private func showFailure(_ message: String) {
        overlay.show(.failure(message))
        status = .failure(message)
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
