import AppKit
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

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Системна"
        case .light: "Світла"
        case .dark: "Темна"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
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

extension MeetingShortcut: Identifiable {
    public var id: String { rawValue }

    var title: String { self == .none ? "Вимкнено" : symbol }
}

/// User-configurable settings persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var hotkey: HotkeyKey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var handsFreeEnabled: Bool { didSet { defaults.set(handsFreeEnabled, forKey: "handsFreeEnabled") } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: "language") } }
    /// Meeting language chosen explicitly; nil means it follows the dictation language.
    @Published var meetingLanguageOverride: Language? {
        didSet { defaults.set(meetingLanguageOverride?.rawValue, forKey: "meetingLanguage") }
    }
    /// Language for meeting transcription. Tracks `language` unless the user picked one.
    var meetingLanguage: Language { meetingLanguageOverride ?? language }
    /// CoreAudio device UID of the preferred microphone; nil means the system default.
    @Published var microphoneID: String? { didSet { defaults.set(microphoneID, forKey: "microphoneID") } }
    @Published var meetingShortcut: MeetingShortcut { didSet { defaults.set(meetingShortcut.rawValue, forKey: "meetingShortcut") } }
    /// Apps whose microphone use makes Shepit offer to record a meeting.
    @Published var callApps: [CallApp] {
        didSet { defaults.set(try? JSONEncoder().encode(callApps), forKey: "callApps") }
    }
    /// Where meeting Markdown files are saved.
    @Published var meetingsFolder: URL { didSet { defaults.set(meetingsFolder.path, forKey: "meetingsFolder") } }

    static let defaultMeetingsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Shepit Meetings", isDirectory: true)

    init() {
        defaults.register(defaults: ["handsFreeEnabled": true, "soundsEnabled": true])
        hotkey = defaults.string(forKey: "hotkey").flatMap(HotkeyKey.init) ?? .rightOption
        handsFreeEnabled = defaults.bool(forKey: "handsFreeEnabled")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        appearance = defaults.string(forKey: "appearance").flatMap(AppearanceMode.init) ?? .system
        language = defaults.string(forKey: "language").flatMap(Language.init) ?? .auto
        meetingLanguageOverride = defaults.string(forKey: "meetingLanguage").flatMap(Language.init)
        microphoneID = defaults.string(forKey: "microphoneID")
        meetingShortcut = defaults.string(forKey: "meetingShortcut").flatMap(MeetingShortcut.init) ?? .controlOptionM
        callApps = defaults.data(forKey: "callApps").flatMap { try? JSONDecoder().decode([CallApp].self, from: $0) }
            ?? CallApp.defaults
        meetingsFolder = defaults.string(forKey: "meetingsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultMeetingsFolder
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
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemPath")
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static var isAnotherInstanceRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me }
    }

    /// The login item remembers the bundle that registered it, so one enabled from a dev build
    /// keeps launching that build; the copy in /Applications takes it over.
    static func pointAtInstalledCopy() {
        let path = Bundle.main.bundlePath
        let key = "loginItemPath"
        // Registering shows a "Background item added" notice, so only when the path actually changed.
        guard isEnabled, path.hasPrefix("/Applications/"), UserDefaults.standard.string(forKey: key) != path else { return }
        do {
            try SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(path, forKey: key)
            Log.info("login item now launches \(path)")
        } catch {
            Log.info("login item not moved to \(Bundle.main.bundlePath): \(error)")
        }
    }
}
