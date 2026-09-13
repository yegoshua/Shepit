import AppKit
import ShepitCore

/// Global keyboard tap translating the configured hotkey and Esc into `PushToTalk` events.
/// A CGEventTap (rather than an NSEvent monitor) is needed so Esc can be swallowed.
/// Requires the Accessibility permission; `start()` fails until it is granted.
final class KeyboardTap {
    private static let escapeKeyCode: Int64 = 53

    /// Receives an event and the moment it was typed (seconds since boot, same clock as
    /// `ProcessInfo.systemUptime`) on the main thread; returns true to swallow the key event.
    private let handler: (PushToTalk.Event, TimeInterval) -> Bool
    private var tap: CFMachPort?
    private var isHotkeyDown = false
    /// Set when an Esc press was swallowed, so its auto-repeats and release are swallowed too.
    private var isSwallowingEscape = false

    /// Chord that toggles meeting recording; its key presses are swallowed.
    var meetingShortcut = MeetingShortcut.none
    /// Called on the main thread when the meeting shortcut is pressed.
    var onMeetingShortcut: (() -> Void)?

    var hotkey: HotkeyKey {
        didSet { if hotkey != oldValue { isHotkeyDown = false } }
    }

    init(hotkey: HotkeyKey, handler: @escaping (PushToTalk.Event, TimeInterval) -> Bool) {
        self.hotkey = hotkey
        self.handler = handler
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    func start() -> Bool {
        guard tap == nil else { return true }

        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                let this = Unmanaged<KeyboardTap>.fromOpaque(context!).takeUnretainedValue()
                return this.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged where keyCode == hotkey.keyCode:
            let down = hotkey.isPressed(flags: event.flags.rawValue)
            guard down != isHotkeyDown else { break }
            isHotkeyDown = down
            _ = handler(down ? .keyDown : .keyUp, Self.typedAt(event))

        case .keyDown where meetingShortcut.matches(keyCode: keyCode, flags: event.flags.rawValue):
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onMeetingShortcut?() }
            return nil

        case .keyDown where keyCode == Self.escapeKeyCode:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                if isSwallowingEscape { return nil }
                break
            }
            if handler(.escape, Self.typedAt(event)) {
                isSwallowingEscape = true
                return nil
            }

        case .keyUp where keyCode == Self.escapeKeyCode && isSwallowingEscape:
            isSwallowingEscape = false
            return nil

        default:
            break
        }
        return passThrough
    }

    /// Events can queue up while the main thread is busy (e.g. starting the microphone),
    /// so timing rules must use when the key was typed, not when we got to it.
    private static func typedAt(_ event: CGEvent) -> TimeInterval {
        NSEvent(cgEvent: event)?.timestamp ?? ProcessInfo.processInfo.systemUptime
    }
}
