import AppKit

/// Push-to-talk on the right Option key. Global monitors need Accessibility permission.
final class HotkeyMonitor {
    private static let rightOptionKeyCode: UInt16 = 61

    private var monitors: [Any] = []
    private var isPressed = false
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange

        let handle: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let pressed = event.modifierFlags.contains(.option)
        guard pressed != isPressed else { return }
        isPressed = pressed
        onChange(pressed)
    }
}
