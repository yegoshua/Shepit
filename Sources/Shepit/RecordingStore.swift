import AVFoundation
import ShepitCore

/// Raw meeting audio under Application Support, outside the meetings folder so synced folders stay small.
/// Each recording is `<id> mic.caf`, an optional `<id> system.caf`, `<id> dictation.json` and `<id> recording.json`.
enum RecordingStore {
    struct Tracks: Equatable {
        var microphone: URL
        /// nil when system audio couldn't be captured, so "Others" can't be heard.
        var systemAudio: URL?
        /// JSON list of dictation intervals, saved next to the audio so they outlive a crash.
        var dictation: URL
    }

    static func folder() throws -> URL {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Shepit/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Recording ID for a start time, e.g. `2026-09-13 14-30-05`.
    static func id(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Where a recording's files go; `systemAudio` is set only when that file exists.
    static func tracks(_ id: String) throws -> Tracks {
        let system = try file(id, "system.caf")
        return Tracks(
            microphone: try file(id, "mic.caf"),
            systemAudio: FileManager.default.fileExists(atPath: system.path) ? system : nil,
            dictation: try file(id, "dictation.json")
        )
    }

    static func systemAudioURL(_ id: String) throws -> URL {
        try file(id, "system.caf")
    }

    static func hasAudio(_ id: String) -> Bool {
        guard let url = try? file(id, "mic.caf") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func save(_ manifest: RecordingManifest) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: try file(manifest.id, "recording.json"), options: .atomic)
        } catch {
            Log.info("recording manifest not saved: \(error)")
        }
    }

    /// Every recording that still has a manifest, oldest first.
    static func all() -> [RecordingManifest] {
        guard let folder = try? folder(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names
            .filter { $0.hasSuffix(" recording.json") }
            .compactMap { try? decoder.decode(RecordingManifest.self, from: Data(contentsOf: folder.appendingPathComponent($0))) }
            .sorted { $0.startDate < $1.startDate }
    }

    static func dictation(_ id: String) -> [DictationInterval] {
        guard let url = try? file(id, "dictation.json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DictationInterval].self, from: data)) ?? []
    }

    /// Length of the microphone track, for a recording cut short by a crash before its duration was saved.
    static func recordedDuration(_ id: String) -> TimeInterval? {
        guard let url = try? file(id, "mic.caf"), let audio = try? AVAudioFile(forReading: url),
              audio.fileFormat.sampleRate > 0
        else { return nil }
        return Double(audio.length) / audio.fileFormat.sampleRate
    }

    /// Removes the audio, dictation intervals and manifest of a recording.
    static func delete(_ id: String) {
        for suffix in ["mic.caf", "system.caf", "dictation.json", "recording.json"] {
            guard let url = try? file(id, suffix), FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Log.info("recording file not deleted: \(url.lastPathComponent): \(error)")
            }
        }
    }

    private static func file(_ id: String, _ suffix: String) throws -> URL {
        try folder().appendingPathComponent("\(id) \(suffix)")
    }
}
