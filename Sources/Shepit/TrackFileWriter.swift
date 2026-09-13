import AVFoundation

/// Resamples captured buffers to 16 kHz mono and appends them to a 16-bit PCM CAF file.
/// Uncompressed CAF stays readable up to the last written buffer if the app is killed
/// mid-recording; AAC in CAF or M4A would lose the packet table and be unplayable.
final class TrackFileWriter {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var isClosed = false
    private var loggedWriteError = false

    init(url: URL, inputFormat: AVAudioFormat) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "TrackFileWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Непідтримуваний аудіоформат"])
        }
        converter.downmix = true
        self.targetFormat = targetFormat
        self.converter = converter
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
            guard !isClosed, let output = AudioRecorder.resample(buffer, with: converter, to: targetFormat) else { return }
            do {
                try file.write(from: output)
            } catch where !loggedWriteError {
                loggedWriteError = true
                Log.info("meeting audio write failed: \(error)")
            } catch {}
        }
    }

    func close() {
        lock.withLock { isClosed = true }
    }
}
