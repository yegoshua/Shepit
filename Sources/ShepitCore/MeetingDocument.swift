import Foundation

/// A piece of recognized speech, with offsets in seconds from the start of the recording.
public struct TranscriptSegment: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct MeetingMetadata: Equatable, Sendable {
    public enum NotesStatus: String, Sendable {
        case none
        case localLLM = "local-llm"
    }

    public enum AudioStatus: String, Sendable {
        case kept, deleted
    }

    public var startDate: Date
    public var duration: TimeInterval
    /// Where the meeting was captured, e.g. "Zoom".
    public var app: String
    /// Whisper language code, or "auto".
    public var language: String
    public var notes: NotesStatus
    public var audio: AudioStatus

    public init(startDate: Date, duration: TimeInterval, app: String, language: String,
                notes: NotesStatus, audio: AudioStatus) {
        self.startDate = startDate
        self.duration = duration
        self.app = app
        self.language = language
        self.notes = notes
        self.audio = audio
    }
}

/// Turns a finished meeting recording into its Markdown file.
public enum MeetingDocument {
    /// `me` is the microphone track; `others` is system audio, empty when it wasn't captured.
    public static func markdown(me: [TranscriptSegment], others: [TranscriptSegment] = [], metadata: MeetingMetadata,
                                timeZone: TimeZone = .current) -> String {
        var lines = [
            "---",
            "date: \(format(metadata.startDate, "yyyy-MM-dd'T'HH:mm", timeZone))",
            "duration: \(duration(metadata.duration))",
            "app: \(metadata.app)",
            "language: \(metadata.language)",
            "notes: \(metadata.notes.rawValue)",
            "audio: \(metadata.audio.rawValue)",
            "---",
            "# Meeting \(format(metadata.startDate, "d MMM HH:mm", timeZone)) (\(metadata.app))",
            "",
            "## Transcript",
            "",
        ]
        let others = others.filter(isSpeech)
        let me = me.filter { isSpeech($0) && !isEcho($0, of: others) }
        let spoken = me.map { ($0, "Me") } + others.map { ($0, "Others") }
        for (segment, speaker) in spoken.sorted(by: { $0.0.start < $1.0.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lines += ["**[\(timestamp(segment.start))] \(speaker):** \(text)", ""]
        }
        return lines.joined(separator: "\n")
    }

    /// Default file name, e.g. `2026-09-13 14-30 Zoom.md`.
    public static func fileName(startDate: Date, app: String, timeZone: TimeZone = .current) -> String {
        // Finder shows ":" as "/" and "/" can't appear in a file name at all.
        let safeApp = app.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        return "\(format(startDate, "yyyy-MM-dd HH-mm", timeZone)) \(safeApp).md"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Whole minutes, as `47m` or `1h 36m`.
    private static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded())
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Segments this long carrying only a few words are Whisper filling silence ("Thank you.").
    private static let hallucinationMinimumDuration: TimeInterval = 10
    private static let hallucinationMaximumWords = 3

    private static func isSpeech(_ segment: TranscriptSegment) -> Bool {
        guard segment.text.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        let words = segment.text.split(whereSeparator: \.isWhitespace).count
        return segment.end - segment.start < hallucinationMinimumDuration || words > hallucinationMaximumWords
    }

    /// The microphone picks up the speakers when there are no headphones, so the same phrase
    /// can appear on both tracks; the system audio copy is the clean one.
    private static let echoWindow: TimeInterval = 1.5
    /// Dice coefficient over normalized words above which two phrases count as the same.
    private static let echoSimilarity = 0.6

    private static func isEcho(_ segment: TranscriptSegment, of others: [TranscriptSegment]) -> Bool {
        let words = normalizedWords(segment.text)
        return others.contains { other in
            abs(other.start - segment.start) <= echoWindow && similarity(words, normalizedWords(other.text)) >= echoSimilarity
        }
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var remaining = b
        var shared = 0
        for word in a {
            if let index = remaining.firstIndex(of: word) {
                remaining.remove(at: index)
                shared += 1
            }
        }
        return 2 * Double(shared) / Double(a.count + b.count)
    }

    /// `mm:ss`; minutes keep counting past an hour.
    private static func timestamp(_ offset: TimeInterval) -> String {
        let seconds = max(0, Int(offset))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
