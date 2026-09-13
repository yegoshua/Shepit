import AVFoundation
import CoreAudio

/// Captures a microphone and resamples to 16 kHz mono Float32, the format Whisper expects.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// A fresh engine per recording, so switching input devices never fights stale engine state.
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakDecibels: Float = -.infinity
    private var smoothedLevel: Float = 0

    /// Called on the main thread with the loudness (0...1) of each captured buffer.
    var onLevel: ((Float) -> Void)?

    /// Records from the device with this CoreAudio UID when it's connected, else from the system default.
    func start(preferredDeviceID: String?) throws {
        engine = Self.makeEngine(preferredDeviceID: preferredDeviceID)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Непідтримуваний аудіоформат"])
        }

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            peakDecibels = -.infinity
            smoothedLevel = 0
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let output = Self.resample(buffer, with: converter, to: targetFormat),
                  let channel = output.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }

            let decibels = Self.decibels(chunk)
            self.lock.withLock { self.peakDecibels = max(self.peakDecibels, decibels) }
            if let onLevel = self.onLevel {
                // Rise instantly, fall gradually so bars don't collapse between syllables.
                let target = Self.normalizedLevel(decibels)
                let level = self.lock.withLock {
                    self.smoothedLevel = max(target, self.smoothedLevel * 0.8)
                    return self.smoothedLevel
                }
                DispatchQueue.main.async { onLevel(level) }
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            Log.info(String(format: "recording stopped: %.1f s, peak %.1f dBFS", Double(samples.count) / Self.sampleRate, peakDecibels))
            return samples
        }
    }

    /// A fresh engine recording from the device with this CoreAudio UID when it's connected, else from the system default.
    static func makeEngine(preferredDeviceID: String?) -> AVAudioEngine {
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

    /// Converts one captured buffer; the converter keeps resampler state between calls.
    static func resample(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        converter.convert(to: output, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return output
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

    static func decibels(_ chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return -120 }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }

    /// Built-in mics deliver normal speech around -45...-25 dBFS (peaks near -20), so map
    /// -55...-28 dBFS onto 0...1 and lift quiet parts with a curve.
    private static func normalizedLevel(_ decibels: Float) -> Float {
        let linear = min(max((decibels + 55) / 27, 0), 1)
        return pow(linear, 0.6)
    }
}
