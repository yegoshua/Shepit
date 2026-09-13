import AVFoundation
import CoreAudio

/// One microphone engine fanned out to every consumer, so dictation can run during a
/// meeting recording without either restarting or stealing the other's input.
final class SharedMicrophone {
    typealias Consumer = (AVAudioPCMBuffer) -> Void

    /// Recreated whenever the microphone starts from idle or its device configuration changes.
    private var engine = AVAudioEngine()
    private var preferredDeviceID: String?
    private var configurationObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var consumers: [UUID: Consumer] = [:]

    /// Starts the microphone if nobody is using it yet and adds a consumer built for its format.
    /// While it's already running, `preferredDeviceID` is ignored and the running device is shared.
    /// Call from the main thread; consumers are called on the audio thread and must cope with the
    /// format changing if the device is reconfigured.
    func attach(preferredDeviceID: String?, makeConsumer: (AVAudioFormat) throws -> Consumer) throws -> UUID {
        let isRunning = lock.withLock { !consumers.isEmpty }
        if !isRunning {
            self.preferredDeviceID = preferredDeviceID
            engine = Self.makeEngine(preferredDeviceID: preferredDeviceID)
        }
        let consumer = try makeConsumer(engine.inputNode.outputFormat(forBus: 0))
        let id = UUID()
        lock.withLock { consumers[id] = consumer }
        guard !isRunning else { return id }

        do {
            try startEngine()
        } catch {
            lock.withLock { consumers[id] = nil }
            throw error
        }
        Log.info("microphone started")
        return id
    }

    /// Removes a consumer; the microphone stops once the last one is gone. Call from the main thread.
    func detach(_ id: UUID) {
        let isEmpty = lock.withLock {
            consumers[id] = nil
            return consumers.isEmpty
        }
        guard isEmpty else { return }
        stopEngine()
        Log.info("microphone stopped")
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            for consumer in self.lock.withLock({ Array(self.consumers.values) }) { consumer(buffer) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        // A device unplugged or switched stops the engine; restart it so a meeting and later dictations keep their input.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    private func stopEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func restartAfterConfigurationChange() {
        guard lock.withLock({ !consumers.isEmpty }) else { return }
        Log.info("microphone configuration changed, restarting")
        stopEngine()
        engine = Self.makeEngine(preferredDeviceID: preferredDeviceID)
        do {
            try startEngine()
        } catch {
            Log.info("microphone restart failed: \(error)")
        }
    }

    /// A fresh engine recording from the device with this CoreAudio UID when it's connected, else from the system default.
    private static func makeEngine(preferredDeviceID: String?) -> AVAudioEngine {
        let engine = AVAudioEngine()
        guard let preferredDeviceID else { return engine }
        guard let device = audioDeviceID(forUID: preferredDeviceID) else {
            Log.info("microphone \(preferredDeviceID) not connected, using system default")
            return engine
        }
        do {
            try select(device, on: engine.inputNode)
            return engine
        } catch {
            Log.info("microphone \(preferredDeviceID) could not be selected, using system default: \(error)")
            return AVAudioEngine()
        }
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func select(_ device: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { return }
        var device = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Не вдалося вибрати мікрофон"])
        }
    }
}
