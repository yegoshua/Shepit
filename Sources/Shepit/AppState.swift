import AppKit
import AVFoundation
import SwiftUI

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
    private var hotkey: HotkeyMonitor?
    private var modelReady = false

    init() {
        hotkey = HotkeyMonitor { [weak self] pressed in
            Task { @MainActor in pressed ? self?.startRecording() : self?.stopRecording() }
        }
        Task { await setUp() }
    }

    func requestAccessibility() {
        TextInserter.promptForTrust()
        // The system dialog is async; poll briefly so the menu updates once granted.
        Task {
            for _ in 0..<60 where !TextInserter.isTrusted {
                try? await Task.sleep(for: .seconds(1))
            }
            hasAccessibility = TextInserter.isTrusted
        }
    }

    private func setUp() async {
        if !hasAccessibility { requestAccessibility() }
        _ = await AVCaptureDevice.requestAccess(for: .audio)

        do {
            try await transcriber.load { [weak self] progress in
                Task { @MainActor in
                    self?.status = .loadingModel("Модель: \(Int(progress * 100))%")
                }
            }
            modelReady = true
            status = .idle
        } catch {
            status = .error("Модель не завантажилась: \(error.localizedDescription)")
        }
    }

    private func startRecording() {
        guard modelReady, status == .idle || status.isError else { return }
        do {
            try recorder.start()
            status = .recording
        } catch {
            status = .error("Мікрофон: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard status == .recording else { return }
        let samples = recorder.stop()
        // Whisper hallucinates on very short clips; ignore accidental taps (< 0.3 s).
        guard samples.count > Int(AudioRecorder.sampleRate * 0.3) else {
            status = .idle
            return
        }

        status = .transcribing
        Task {
            do {
                let text = try await transcriber.transcribe(samples, language: language.whisperCode)
                if !text.isEmpty {
                    lastText = text
                    TextInserter.insert(text)
                }
                status = .idle
            } catch {
                status = .error("Розпізнавання: \(error.localizedDescription)")
            }
        }
    }
}
