import AVFoundation

/// Writes the microphone to a 16 kHz mono 16-bit PCM CAF file as it is captured.
/// Uncompressed CAF stays readable up to the last written buffer if the app is killed
/// mid-recording; AAC in CAF or M4A would lose the packet table and be unplayable.
final class MeetingRecorder {
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var loggedWriteError = false

    func start(writingTo url: URL, preferredDeviceID: String?) throws {
        engine = AudioRecorder.makeEngine(preferredDeviceID: preferredDeviceID)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "MeetingRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Непідтримуваний аудіоформат"])
        }

        let file = try AVAudioFile(
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
        lock.withLock {
            self.file = file
            loggedWriteError = false
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let output = AudioRecorder.resample(buffer, with: converter, to: targetFormat) else { return }
            self.lock.withLock {
                do {
                    try self.file?.write(from: output)
                } catch where !self.loggedWriteError {
                    self.loggedWriteError = true
                    Log.info("meeting audio write failed: \(error)")
                } catch {}
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { self.file = nil }
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Releasing the file finalizes the CAF header.
        lock.withLock { file = nil }
    }
}
