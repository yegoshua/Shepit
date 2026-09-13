import AVFoundation
import Combine
import ServiceManagement
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

extension HotkeyKey: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "Правий ⌥ Option"
        case .rightCommand: "Правий ⌘ Command"
        case .rightShift: "Правий ⇧ Shift"
        case .rightControl: "Правий ⌃ Control"
        }
    }
}

/// User-configurable settings persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var hotkey: HotkeyKey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var handsFreeEnabled: Bool { didSet { defaults.set(handsFreeEnabled, forKey: "handsFreeEnabled") } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: "language") } }
    /// CoreAudio device UID of the preferred microphone; nil means the system default.
    @Published var microphoneID: String? { didSet { defaults.set(microphoneID, forKey: "microphoneID") } }

    init() {
        defaults.register(defaults: ["handsFreeEnabled": true, "soundsEnabled": true])
        hotkey = defaults.string(forKey: "hotkey").flatMap(HotkeyKey.init) ?? .rightOption
        handsFreeEnabled = defaults.bool(forKey: "handsFreeEnabled")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        language = defaults.string(forKey: "language").flatMap(Language.init) ?? .auto
        microphoneID = defaults.string(forKey: "microphoneID")
    }
}

struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Live list of audio input devices.
@MainActor
final class Microphones: ObservableObject {
    @Published private(set) var available: [Microphone] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        available = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Thin wrapper over the system login-item registration for the main app.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
