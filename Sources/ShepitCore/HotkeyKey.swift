/// Right-hand modifier keys that can drive push-to-talk.
public enum HotkeyKey: String, CaseIterable, Sendable {
    case rightOption, rightCommand, rightShift, rightControl

    /// macOS virtual key code reported with the flags-changed event.
    public var keyCode: Int64 {
        switch self {
        case .rightCommand: 54
        case .rightShift: 60
        case .rightOption: 61
        case .rightControl: 62
        }
    }

    public var symbol: String {
        switch self {
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .rightShift: "⇧"
        case .rightControl: "⌃"
        }
    }

    /// Whether this specific right-hand key is down, judged from raw CGEvent flags.
    /// Uses the device-dependent bit so the left-hand twin doesn't count.
    public func isPressed(flags: UInt64) -> Bool {
        flags & deviceMask != 0
    }

    /// NX_DEVICER*KEYMASK from IOKit's IOLLEvent.h.
    private var deviceMask: UInt64 {
        switch self {
        case .rightShift: 0x0000_0004
        case .rightCommand: 0x0000_0010
        case .rightOption: 0x0000_0040
        case .rightControl: 0x0000_2000
        }
    }
}
