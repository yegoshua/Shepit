import AVFoundation

/// Converts captured buffers to 16 kHz mono Float32, the format Whisper expects. Rebuilds its
/// converter when the input format changes mid-recording, e.g. after switching microphones.
/// Not thread-safe: feed it from one audio thread at a time.
final class Resampler {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter

    init(inputFormat: AVAudioFormat) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
        ), let converter = Self.makeConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "Resampler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Непідтримуваний аудіоформат"])
        }
        self.targetFormat = targetFormat
        self.converter = converter
    }

    /// The converter keeps resampler state between calls, so one instance serves one continuous stream.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format != converter.inputFormat {
            guard let replacement = Self.makeConverter(from: buffer.format, to: targetFormat) else { return nil }
            Log.info("input format changed to \(buffer.format)")
            converter = replacement
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
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

    private static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: input, to: output)
        converter?.downmix = true
        return converter
    }
}
