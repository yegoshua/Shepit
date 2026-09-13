import AppKit
import ShepitCore

/// Global keyboard tap translating the right Option key and Esc into `PushToTalk` events.
/// A CGEventTap (rather than an NSEvent monitor) is needed so Esc can be swallowed.
/// Requires the Accessibility permission; `start()` fails until it is granted.
final class KeyboardTap {
    private static let rightOptionKeyCode: Int64 = 61
    private static let escapeKeyCode: Int64 = 53

    /// Receives an event on the main thread and returns true to swallow the underlying key event.
    private let handler: (PushToTalk.Event) -> Bool
    private var tap: CFMachPort?
    private var isOptionDown = false

    init(handler: @escaping (PushToTalk.Event) -> Bool) {
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

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged where keyCode == Self.rightOptionKeyCode:
            let down = event.flags.contains(.maskAlternate)
            guard down != isOptionDown else { break }
            isOptionDown = down
            _ = handler(down ? .optionDown : .optionUp)

        case .keyDown where keyCode == Self.escapeKeyCode:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { break }
            if handler(.escape) { return nil }

        default:
            break
        }
        return passThrough
    }
}
