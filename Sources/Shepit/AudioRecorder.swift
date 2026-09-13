import AVFoundation

/// Captures the default microphone and resamples to 16 kHz mono Float32, the format Whisper expects.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []

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

        lock.withLock { samples.removeAll(keepingCapacity: true) }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
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

            if let onLevel = self.onLevel {
                let level = Self.normalizedLevel(chunk)
                DispatchQueue.main.async { onLevel(level) }
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }

    /// Maps RMS of a buffer from -50...0 dBFS onto 0...1.
    private static func normalizedLevel(_ chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
