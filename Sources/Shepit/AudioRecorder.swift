import AVFoundation

/// Captures dictation from the shared microphone and resamples to 16 kHz mono Float32, the format Whisper expects.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let microphone: SharedMicrophone
    private var consumerID: UUID?
    private let lock = NSLock()
    /// Guards against a buffer already on its way from the audio thread landing after `stop()`.
    private var isCapturing = false
    private var samples: [Float] = []
    private var peakDecibels: Float = -.infinity
    private var smoothedLevel: Float = 0

    /// Called on the main thread with the loudness (0...1) of each captured buffer.
    var onLevel: ((Float) -> Void)?

    init(microphone: SharedMicrophone) {
        self.microphone = microphone
    }

    /// Records from the device with this CoreAudio UID when it's connected, else from the system default.
    /// If a meeting is already using the microphone, dictation shares its device.
    func start(preferredDeviceID: String?) throws {
        guard consumerID == nil else { return }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            peakDecibels = -.infinity
            smoothedLevel = 0
            isCapturing = true
        }
        do {
            consumerID = try microphone.attach(preferredDeviceID: preferredDeviceID) { inputFormat in
                try self.consumer(resampler: Resampler(inputFormat: inputFormat))
            }
        } catch {
            lock.withLock { isCapturing = false }
            throw error
        }
    }

    private func consumer(resampler: Resampler) -> SharedMicrophone.Consumer {
        { [weak self] buffer in
            guard let self,
                  let output = resampler.convert(buffer),
                  let channel = output.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            let appended = self.lock.withLock {
                if self.isCapturing { self.samples.append(contentsOf: chunk) }
                return self.isCapturing
            }
            guard appended else { return }

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
    }

    func stop() -> [Float] {
        if let consumerID { microphone.detach(consumerID) }
        consumerID = nil
        return lock.withLock {
            isCapturing = false
            Log.info(String(format: "recording stopped: %.1f s, peak %.1f dBFS", Double(samples.count) / Self.sampleRate, peakDecibels))
            return samples
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
