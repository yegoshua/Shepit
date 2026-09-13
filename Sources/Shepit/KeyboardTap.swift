import AppKit
import ShepitCore

/// Global keyboard tap translating the right Option key and Esc into `PushToTalk` events.
/// A CGEventTap (rather than an NSEvent monitor) is needed so Esc can be swallowed.
/// Requires the Accessibility permission; `start()` fails until it is granted.
final class KeyboardTap {
    private static let rightOptionKeyCode: Int64 = 61
    private static let escapeKeyCode: Int64 = 53

    /// Receives an event and the moment it was typed (seconds since boot, same clock as
    /// `ProcessInfo.systemUptime`) on the main thread; returns true to swallow the key event.
    private let handler: (PushToTalk.Event, TimeInterval) -> Bool
    private var tap: CFMachPort?
    private var isOptionDown = false

    init(handler: @escaping (PushToTalk.Event, TimeInterval) -> Bool) {
        self.handler = handler
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
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
        // Events can queue up while the main thread is busy (e.g. starting the microphone),
        // so timing rules must use when the key was typed, not when we got to it.
        let typedAt = NSEvent(cgEvent: event)?.timestamp ?? ProcessInfo.processInfo.systemUptime

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged where keyCode == Self.rightOptionKeyCode:
            let down = event.flags.contains(.maskAlternate)
            guard down != isOptionDown else { break }
            isOptionDown = down
            _ = handler(down ? .optionDown : .optionUp, typedAt)

        case .keyDown where keyCode == Self.escapeKeyCode:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { break }
            if handler(.escape, typedAt) { return nil }

        default:
            break
        }
        return passThrough
    }
}
