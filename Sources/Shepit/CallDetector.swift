import CoreAudio
import Foundation
import ShepitCore

/// Watches which processes are taking microphone input through Core Audio's process
/// object list (macOS 14.2+) and reports when watched call apps start or stop.
@available(macOS 14.2, *)
@MainActor
final class CallDetector {
    /// Checking a handful of Core Audio properties is cheap; a call lasts minutes, so a couple of seconds' delay is fine.
    private static let pollInterval: TimeInterval = 2

    var apps: [CallApp]
    var onEvents: (@MainActor ([MeetingSession.Event]) -> Void)?

    private var active: Set<String> = []
    private var timer: Timer?

    init(apps: [CallApp]) {
        self.apps = apps
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        let current = CallDetection.activeApps(
            in: Self.audioProcesses(), watching: apps, ownPID: ProcessInfo.processInfo.processIdentifier
        )
        let events = CallDetection.changes(from: active, to: current)
        active = current
        guard !events.isEmpty else { return }
        Log.info("call apps on mic: \(current.sorted())")
        onEvents?(events)
    }

    private static func audioProcesses() -> [AudioInputProcess] {
        let objects: [AudioObjectID] = arrayProperty(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList
        )
        return objects.map { object in
            AudioInputProcess(
                pid: scalarProperty(object, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: stringProperty(object, kAudioProcessPropertyBundleID),
                isRunningInput: scalarProperty(object, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0
            )
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func arrayProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let capacity = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        // The list can shrink between the two calls; `size` now holds what was actually written.
        let count = min(capacity, Int(size) / MemoryLayout<T>.stride)
        return Array(UnsafeBufferPointer(start: pointer.bindMemory(to: T.self, capacity: capacity), count: count))
    }

    private static func scalarProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var address = address(selector)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : value
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr,
              let string = result?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }
}
