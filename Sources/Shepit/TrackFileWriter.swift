import AVFoundation

/// Resamples captured buffers to 16 kHz mono and appends them to a 16-bit PCM CAF file.
/// Uncompressed CAF stays readable up to the last written buffer if the app is killed
/// mid-recording; AAC in CAF or M4A would lose the packet table and be unplayable.
final class TrackFileWriter {
    /// Released on `close()`, which is what writes the final CAF header.
    private var file: AVAudioFile?
    private let resampler: Resampler
    private let lock = NSLock()
    private var loggedWriteError = false
    private var peakDecibels: Float = -.infinity

    init(url: URL, inputFormat: AVAudioFormat) throws {
        resampler = try Resampler(inputFormat: inputFormat)
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioRecorder.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Safe to call from an audio thread; buffers arriving after `close()` are ignored.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file, let output = resampler.convert(buffer) else { return }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                let decibels = AudioRecorder.decibels(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                peakDecibels = max(peakDecibels, decibels)
            }
            do {
                try file.write(from: output)
            } catch where !loggedWriteError {
                loggedWriteError = true
                Log.info("meeting audio write failed: \(error)")
            } catch {}
        }
    }

    /// RMS level of the loudest buffer written since the previous call, in dBFS; `-infinity` when nothing arrived.
    func takeLoudestLevel() -> Float {
        lock.withLock {
            defer { peakDecibels = -.infinity }
            return peakDecibels
        }
    }

    /// Finalizes the file now, even if an audio callback still holds this writer.
    func close() {
        lock.withLock { file = nil }
    }
}
