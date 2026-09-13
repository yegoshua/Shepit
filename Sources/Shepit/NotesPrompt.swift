import Foundation

/// The notes prompt bundled as `NotesPrompt.md`, shared by "Copy with prompt" and local notes.
/// Kept out of code so the wording can change without touching Swift.
enum NotesPrompt {
    enum LoadError: LocalizedError {
        case missing

        var errorDescription: String? { "Файл промпту не знайдено в застосунку. Перезбери його через scripts/bundle.sh." }
    }

    static func text() throws -> String {
        guard let url = Bundle.main.url(forResource: "NotesPrompt", withExtension: "md") else { throw LoadError.missing }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
