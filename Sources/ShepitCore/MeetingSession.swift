import Foundation

/// Decides when a meeting recording starts, stops and asks "Still recording?".
public struct MeetingSession {
    public enum Event: Equatable {
        /// The user asked to record (menu or hotkey).
        case start
        /// Capture actually began; permission prompts can sit between `start` and this.
        case started
        case failedToStart
        /// The user asked to stop (menu or hotkey).
        case stop
        /// Loudest level heard on any track since the previous report, in dBFS.
        case level(decibels: Float)
        case tick
        /// The user's answer to "Still recording?".
        case stillRecording(Bool)
    }

    public enum PromptReason: Equatable, Sendable {
        case longRecording, silence
    }

    public enum Command: Equatable {
        case startRecording, stopRecording
        case askStillRecording(PromptReason)
        case dismissStillRecording
    }

    /// A forgotten recording is questioned after this long.
    public static let longRecordingLimit: TimeInterval = 3 * 60 * 60
    /// …or after this long without a sound on any track.
    public static let silenceLimit: TimeInterval = 10 * 60
    /// Room noise on a built-in mic sits below this; speech, even quiet, is above it.
    public static let silenceThreshold: Float = -50

    private struct Recording {
        /// When the long-recording prompt is due; moves on when the user answers "yes" to it.
        var askLongAt: TimeInterval
        var lastSoundAt: TimeInterval
        /// The question waiting for an answer, if any.
        var asking: PromptReason?
    }

    private enum State {
        case idle
        case starting
        case recording(Recording)
    }

    private var state = State.idle

    public init() {}

    public var isRecording: Bool {
        if case .recording = state { true } else { false }
    }

    public var isAskingStillRecording: Bool {
        if case .recording(let recording) = state { recording.asking != nil } else { false }
    }

    public mutating func handle(_ event: Event, at time: TimeInterval) -> [Command] {
        switch (state, event) {
        case (.idle, .start):
            state = .starting
            return [.startRecording]
        case (.starting, .started):
            state = .recording(Recording(askLongAt: time + Self.longRecordingLimit, lastSoundAt: time))
            return []
        case (.starting, .failedToStart):
            state = .idle
            return []
        case (.recording(let recording), .stop):
            state = .idle
            return recording.asking == nil ? [.stopRecording] : [.dismissStillRecording, .stopRecording]
        case (.recording(var recording), .level(let decibels)) where decibels >= Self.silenceThreshold:
            recording.lastSoundAt = time
            state = .recording(recording)
            return []
        case (.recording(var recording), .tick) where recording.asking == nil:
            guard let reason = promptReason(recording, at: time) else { return [] }
            recording.asking = reason
            state = .recording(recording)
            return [.askStillRecording(reason)]
        case (.recording(let recording), .stillRecording(false)) where recording.asking != nil:
            state = .idle
            return [.dismissStillRecording, .stopRecording]
        case (.recording(var recording), .stillRecording(true)):
            guard let reason = recording.asking else { return [] }
            // The user is evidently there, so the silence timer restarts either way;
            // only a "yes" to the 3-hour question moves that deadline.
            if reason == .longRecording { recording.askLongAt = time + Self.longRecordingLimit }
            recording.lastSoundAt = time
            recording.asking = nil
            state = .recording(recording)
            return [.dismissStillRecording]
        default:
            return []
        }
    }

    private func promptReason(_ recording: Recording, at time: TimeInterval) -> PromptReason? {
        if time >= recording.askLongAt { return .longRecording }
        if time - recording.lastSoundAt >= Self.silenceLimit { return .silence }
        return nil
    }
}
