import Foundation

/// What Shepit knows about one meeting's raw audio, saved next to the tracks so it survives a crash.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Capture was running; still set after launch means Shepit quit or crashed mid-recording.
        case recording
        /// Stopped and waiting for its transcript; still set after launch means processing never finished.
        case stopped
        case transcribed
        case failed
    }

    /// Shared stem of the track files, e.g. `2026-09-13 14-30-05`; also written to the meeting's frontmatter.
    public var id: String
    public var startDate: Date
    /// nil until the recording stops.
    public var duration: TimeInterval?
    /// The detected call app, or "Manual".
    public var app: String
    public var status: Status
    /// Why the last transcription failed.
    public var error: String?

    public init(id: String, startDate: Date, duration: TimeInterval? = nil, app: String,
                status: Status, error: String? = nil) {
        self.id = id
        self.startDate = startDate
        self.duration = duration
        self.app = app
        self.status = status
        self.error = error
    }

    /// Left behind by a quit or crash before its transcript was written.
    public var isUnfinished: Bool { status == .recording || status == .stopped }
}

/// Raw audio holds other people's voices, so it is kept only as long as re-transcribing is likely.
public enum AudioRetention {
    public static let period: TimeInterval = 3 * 24 * 60 * 60

    /// Recordings whose audio should be deleted now: transcribed and at least `period` old.
    /// Anything without a transcript is kept until the user retries or deletes it.
    public static func expired(_ recordings: [RecordingManifest], now: Date) -> [RecordingManifest] {
        recordings.filter { $0.status == .transcribed && now.timeIntervalSince($0.startDate) >= period }
    }
}
