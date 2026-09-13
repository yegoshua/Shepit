import Foundation

/// Decides when a meeting recording starts and stops: by hand, by accepting an offer when a
/// call app takes the microphone, or by answering "Still recording?".
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
        /// A watched call app began using microphone input.
        case callStarted(app: String)
        /// A watched call app stopped using microphone input.
        case callEnded(app: String)
        /// The user accepted the offer on screen: to record a call, or to stop once it ended.
        case offerAccepted
        case offerDismissed
    }

    public enum PromptReason: Equatable, Sendable {
        case longRecording, silence
    }

    public enum Command: Equatable {
        /// `app` is the detected call app, or nil for a recording started by hand.
        case startRecording(app: String?)
        case stopRecording
        case askStillRecording(PromptReason)
        case dismissStillRecording
        case offerToRecord(app: String)
        case offerToStop(app: String)
        case dismissOffer
    }

    /// A forgotten recording is questioned after this long.
    public static let longRecordingLimit: TimeInterval = 3 * 60 * 60
    /// …or after this long without a sound on any track.
    public static let silenceLimit: TimeInterval = 10 * 60
    /// Room noise on a built-in mic sits below this; speech, even quiet, is above it.
    public static let silenceThreshold: Float = -50

    private struct Recording {
        /// The call app this recording was offered for; nil when started by hand.
        var app: String?
        /// When the long-recording prompt is due; moves on when the user answers "yes" to it.
        var askLongAt: TimeInterval
        var lastSoundAt: TimeInterval
        /// The question waiting for an answer, if any.
        var asking: PromptReason?
        /// Set while offering to stop because `app` released the microphone.
        var offeringStop = false

        /// Commands that take down whatever is still on screen before the recording stops.
        var dismissals: [Command] {
            (asking == nil ? [] : [.dismissStillRecording]) + (offeringStop ? [.dismissOffer] : [])
        }
    }

    private enum State {
        case idle
        case offering(app: String)
        /// `callEnded` records that `app` released the mic before capture began.
        case starting(app: String?, callEnded: Bool)
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
            state = .starting(app: nil, callEnded: false)
            return [.startRecording(app: nil)]
        case (.idle, .callStarted(let app)):
            state = .offering(app: app)
            return [.offerToRecord(app: app)]
        case (.offering(let app), .offerAccepted), (.offering(let app), .start):
            state = .starting(app: app, callEnded: false)
            return [.dismissOffer, .startRecording(app: app)]
        case (.offering, .offerDismissed):
            state = .idle
            return [.dismissOffer]
        case (.offering(let offered), .callEnded(let app)) where app == offered:
            state = .idle
            return [.dismissOffer]
        case (.starting(let app, let callEnded), .started):
            state = .recording(Recording(
                app: app, askLongAt: time + Self.longRecordingLimit, lastSoundAt: time, offeringStop: callEnded
            ))
            if callEnded, let app { return [.offerToStop(app: app)] }
            return []
        case (.starting(let app, false), .callEnded(let ended)) where ended == app:
            state = .starting(app: app, callEnded: true)
            return []
        case (.starting(let app, true), .callStarted(let started)) where started == app:
            state = .starting(app: app, callEnded: false)
            return []
        case (.starting, .failedToStart):
            state = .idle
            return []
        case (.recording(let recording), .stop):
            state = .idle
            return recording.dismissals + [.stopRecording]
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
            return recording.dismissals + [.stopRecording]
        case (.recording(var recording), .stillRecording(true)):
            guard let reason = recording.asking else { return [] }
            // The user is evidently there, so the silence timer restarts either way;
            // only a "yes" to the 3-hour question moves that deadline.
            if reason == .longRecording { recording.askLongAt = time + Self.longRecordingLimit }
            recording.lastSoundAt = time
            recording.asking = nil
            state = .recording(recording)
            return [.dismissStillRecording]
        case (.recording(var recording), .callEnded(let app)) where app == recording.app && !recording.offeringStop:
            recording.offeringStop = true
            state = .recording(recording)
            return [.offerToStop(app: app)]
        case (.recording(var recording), .callStarted(let app)) where app == recording.app && recording.offeringStop:
            // Back on the mic (e.g. rejoined), so the call isn't over after all.
            recording.offeringStop = false
            state = .recording(recording)
            return [.dismissOffer]
        case (.recording(let recording), .offerAccepted) where recording.offeringStop:
            state = .idle
            return recording.dismissals + [.stopRecording]
        case (.recording(var recording), .offerDismissed) where recording.offeringStop:
            recording.offeringStop = false
            state = .recording(recording)
            return [.dismissOffer]
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
