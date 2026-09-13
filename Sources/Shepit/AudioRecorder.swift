import AVFoundation

/// Captures the default microphone and resamples to 16 kHz mono Float32, the format Whisper expects.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakDecibels: Float = -.infinity

    /// Called on the main thread with the loudness (0...1) of each captured buffer.
    var onLevel: ((Float) -> Void)?

    func start() throws {
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
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

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

            guard let channel = output.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }

            let decibels = Self.decibels(chunk)
            self.lock.withLock { self.peakDecibels = max(self.peakDecibels, decibels) }
            if let onLevel = self.onLevel {
                let level = Self.normalizedLevel(decibels)
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

    private static func decibels(_ chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return -120 }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }

    /// Built-in mics deliver normal speech around -45...-25 dBFS, so map -60...-20 dBFS onto 0...1
    /// and lift quiet parts with a gentle curve.
    private static func normalizedLevel(_ decibels: Float) -> Float {
        let linear = min(max((decibels + 60) / 40, 0), 1)
        return pow(linear, 0.7)
    }
}
