import AppKit
import AVFoundation
import SwiftUI
import ShepitCore

enum Language: String, CaseIterable, Identifiable {
    case auto, uk, en, ru

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Автовизначення"
        case .uk: "Українська"
        case .en: "English"
        case .ru: "Русский"
        }
    }
    /// nil means Whisper detects the language itself.
    var whisperCode: String? { self == .auto ? nil : rawValue }
}

enum Status: Equatable {
    case loadingModel(String)
    case idle
    case recording
    case transcribing
    case error(String)

    var title: String {
        switch self {
        case .loadingModel(let detail): detail
        case .idle: "Готово"
        case .recording: "Слухаю…"
        case .transcribing: "Розпізнаю…"
        case .error(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .loadingModel: "arrow.down.circle"
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .error: "exclamationmark.triangle"
        }
    }

    var isError: Bool { if case .error = self { true } else { false } }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: Status = .loadingModel("Завантаження моделі…")
    @Published var lastText = ""
    @Published var hasAccessibility = TextInserter.isTrusted
    @AppStorage("language") var language: Language = .auto

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let overlay = RecordingOverlay()
    private var pushToTalk = PushToTalk()
    private var keyboard: KeyboardTap?
    private var ticker: Timer?
    private var recordingStartedAt = Date()
    private var modelReady = false
    private var isTranscribing = false

    init() {
        keyboard = KeyboardTap { [weak self] event, time in
            MainActor.assumeIsolated { self?.handle(event, at: time) ?? false }
        }
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.overlay.push(level: level) }
        }
        Task { await setUp() }
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

    /// Returns true when the key event should be swallowed.
    private func handle(_ event: PushToTalk.Event, at time: TimeInterval) -> Bool {
        guard modelReady, !isTranscribing else { return false }
        let wasRecording = pushToTalk.isRecording
        pushToTalk.handle(event, at: time).forEach(execute)
        return event == .escape && wasRecording
    }

    private func execute(_ command: PushToTalk.Command) {
        switch command {
        case .start: startRecording()
        case .enterHandsFree: overlay.show(.recording(handsFree: true, startedAt: recordingStartedAt))
        case .finish: finishRecording()
        case .cancel, .discard: abortRecording()
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
        } catch {
            pushToTalk = PushToTalk()
            status = .error("Мікрофон: \(error.localizedDescription)")
            return
        }
        recordingStartedAt = Date()
        status = .recording
        NSSound(named: "Tink")?.play()
        overlay.show(.recording(handsFree: false, startedAt: recordingStartedAt))
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.handle(.tick, at: ProcessInfo.processInfo.systemUptime) }
        }
    }

    private func abortRecording() {
        stopTicker()
        _ = recorder.stop()
        overlay.hide()
        status = .idle
    }

    private func finishRecording() {
        stopTicker()
        let samples = recorder.stop()
        NSSound(named: "Pop")?.play()

        isTranscribing = true
        status = .transcribing
        overlay.show(.transcribing)
        Task {
            defer { isTranscribing = false }
            do {
                let text = try await transcriber.transcribe(samples, language: language.whisperCode)
                guard !text.isEmpty else {
                    overlay.show(.failure("нічого не розпізнано"))
                    status = .idle
                    return
                }
                lastText = text
                TextInserter.insert(text)
                overlay.show(.success)
                status = .idle
            } catch {
                overlay.show(.failure("нічого не розпізнано"))
                status = .error("Розпізнавання: \(error.localizedDescription)")
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
