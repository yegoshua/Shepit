/// Global key chord that starts and stops a meeting recording.
public enum MeetingShortcut: String, CaseIterable, Sendable {
    case none, controlOptionM, controlOptionR, controlOptionCommandM

    private static let shift: UInt64 = 0x2_0000
    private static let control: UInt64 = 0x4_0000
    private static let option: UInt64 = 0x8_0000
    private static let command: UInt64 = 0x10_0000
    private static let chordModifiers = shift | control | option | command

    /// macOS virtual key code of the non-modifier key.
    private var keyCode: Int64? {
        switch self {
        case .none: nil
        case .controlOptionM, .controlOptionCommandM: 46
        case .controlOptionR: 15
        }
    }

    /// CGEventFlags masks that must be held, and no other chord modifiers.
    private var modifiers: UInt64 {
        switch self {
        case .none: 0
        case .controlOptionM, .controlOptionR: Self.control | Self.option
        case .controlOptionCommandM: Self.control | Self.option | Self.command
        }
    }

    public var symbol: String {
        switch self {
        case .none: ""
        case .controlOptionM: "⌃⌥M"
        case .controlOptionR: "⌃⌥R"
        case .controlOptionCommandM: "⌃⌥⌘M"
        }
    }

    /// Whether a key-down with these raw CGEvent flags is this chord.
    public func matches(keyCode: Int64, flags: UInt64) -> Bool {
        guard let expected = self.keyCode else { return false }
        return keyCode == expected && flags & Self.chordModifiers == modifiers
    }
}
