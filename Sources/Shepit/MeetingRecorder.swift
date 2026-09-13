import AVFoundation

/// Records a meeting as separate track files: the microphone ("Me") and, when allowed,
/// system audio ("Others").
final class MeetingRecorder {
    private let microphone: SharedMicrophone
    private var microphoneConsumerID: UUID?
    private var microphoneWriter: TrackFileWriter?
    /// `SystemAudioTap` on macOS 14.2+; typed loosely because stored properties can't be availability-gated.
    private var systemAudio: AnyObject?

    init(microphone: SharedMicrophone) {
        self.microphone = microphone
    }

    /// Shares the microphone with dictation, so pressing the hotkey mid-meeting never interrupts this track.
    func startMicrophone(writingTo url: URL, preferredDeviceID: String?) throws {
        var writer: TrackFileWriter?
        microphoneConsumerID = try microphone.attach(preferredDeviceID: preferredDeviceID) { inputFormat in
            let trackWriter = try TrackFileWriter(url: url, inputFormat: inputFormat)
            writer = trackWriter
            return { buffer in trackWriter.write(buffer) }
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
        if let microphoneConsumerID { microphone.detach(microphoneConsumerID) }
        microphoneConsumerID = nil
        microphoneWriter?.close()
        microphoneWriter = nil
        if #available(macOS 14.2, *), let tap = systemAudio as? SystemAudioTap {
            tap.stop()
        }
        systemAudio = nil
    }
}
