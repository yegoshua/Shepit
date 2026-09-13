import AVFoundation

/// Records a meeting as separate track files: the microphone ("Me") and, when allowed,
/// system audio ("Others").
final class MeetingRecorder {
    private var engine = AVAudioEngine()
    private var microphoneWriter: TrackFileWriter?
    /// `SystemAudioTap` on macOS 14.2+; typed loosely because stored properties can't be availability-gated.
    private var systemAudio: AnyObject?

    func startMicrophone(writingTo url: URL, preferredDeviceID: String?) throws {
        engine = AudioRecorder.makeEngine(preferredDeviceID: preferredDeviceID)
        let input = engine.inputNode
        let writer = try TrackFileWriter(url: url, inputFormat: input.outputFormat(forBus: 0))
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in writer.write(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            writer.close()
            throw error
        }
        microphoneWriter = writer
    }

    @available(macOS 14.2, *)
    func startSystemAudio(writingTo url: URL) throws {
        let tap = SystemAudioTap()
        try tap.start(writingTo: url)
        systemAudio = tap
    }

    /// Loudest level on either track since the previous call, in dBFS.
    func takeLoudestLevel() -> Float {
        var peak = microphoneWriter?.takeLoudestLevel() ?? -.infinity
        if #available(macOS 14.2, *), let tap = systemAudio as? SystemAudioTap {
            peak = max(peak, tap.takeLoudestLevel())
        }
        return peak
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Each file's CAF header is finalized once its last capture callback lets go of the writer.
        microphoneWriter?.close()
        microphoneWriter = nil
        if #available(macOS 14.2, *), let tap = systemAudio as? SystemAudioTap {
            tap.stop()
        }
        systemAudio = nil
    }
}
