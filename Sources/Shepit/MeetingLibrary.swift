import AppKit
import Combine
import ShepitCore

struct MeetingItem: Identifiable, Equatable {
    var url: URL
    var title: String
    var date: Date
    var markdown: String
    var modified: Date

    var id: URL { url }
}

/// The meetings folder as the source of truth: whatever Markdown files are in it,
/// including ones added, edited or removed outside Shepit.
@MainActor
final class MeetingLibrary: ObservableObject {
    @Published private(set) var items: [MeetingItem] = []
    @Published var selection: URL?

    private let preferences: Preferences
    private var poller: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    /// Folder changes outside Shepit are picked up by re-reading it this often while the window is open.
    private static let pollInterval: TimeInterval = 2

    init(preferences: Preferences) {
        self.preferences = preferences
        preferences.$meetingsFolder
            .dropFirst()
            .sink { [weak self] _ in
                // The publisher fires before the property changes.
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &subscriptions)
    }

    var folder: URL { preferences.meetingsFolder }
    var selectedItem: MeetingItem? { items.first { $0.url == selection } }

    func startWatching() {
        refresh()
        guard poller == nil else { return }
        let poller = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Common modes keep polling while the window is being resized or a menu is open.
        RunLoop.main.add(poller, forMode: .common)
        self.poller = poller
    }

    func stopWatching() {
        poller?.invalidate()
        poller = nil
    }

    func refresh() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        let known = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })

        let loaded: [MeetingItem] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "md",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { return nil }
            let modified = values.contentModificationDate ?? .distantPast
            if let item = known[url], item.modified == modified { return item }
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return MeetingItem(
                url: url,
                title: MeetingDocument.title(of: markdown) ?? url.deletingPathExtension().lastPathComponent,
                date: MeetingDocument.meetingDate(of: markdown) ?? values.creationDate ?? modified,
                markdown: markdown,
                modified: modified
            )
        }
        let sorted = loaded.sorted { $0.date == $1.date ? $0.title < $1.title : $0.date > $1.date }
        if sorted != items { items = sorted }
        if let selection, !items.contains(where: { $0.url == selection }) { self.selection = nil }
        if selection == nil { selection = items.first?.url }
    }

    /// Opens the library on a specific file, e.g. from the "Transcript ready" notification.
    func select(_ url: URL) {
        refresh()
        let target = url.standardizedFileURL
        selection = items.first { $0.url.standardizedFileURL == target }?.url ?? selection
    }

    enum RenameError: LocalizedError {
        case emptyTitle

        var errorDescription: String? { "Назва має містити хоча б одну літеру чи цифру." }
    }

    /// Changes the title heading and renames the file to match, never overwriting another meeting.
    func rename(_ item: MeetingItem, to title: String) throws {
        guard let name = MeetingDocument.fileName(forTitle: title) else { throw RenameError.emptyTitle }
        let fileManager = FileManager.default
        let directory = item.url.deletingLastPathComponent()
        let markdown = try String(contentsOf: item.url, encoding: .utf8)
        let others = Set(try fileManager.contentsOfDirectory(atPath: directory.path)).subtracting([item.url.lastPathComponent])
        let destination = directory.appendingPathComponent(MeetingDocument.unusedFileName(name, existing: others))

        defer { refresh() }
        let moves = destination.lastPathComponent != item.url.lastPathComponent
        if moves { try fileManager.moveItem(at: item.url, to: destination) }
        do {
            // Written in place rather than atomically so the file keeps its creation date.
            try MeetingDocument.retitled(markdown, to: title).write(to: destination, atomically: false, encoding: .utf8)
        } catch {
            // Keep file name and title consistent: undo the move.
            if moves { try? fileManager.moveItem(at: destination, to: item.url) }
            throw error
        }
        selection = destination
    }

    /// Puts the notes prompt and the meeting's transcript on the clipboard.
    /// Reads the file afresh so an edit made seconds ago outside Shepit isn't missed.
    func copyWithPrompt(_ item: MeetingItem) throws {
        let markdown = try String(contentsOf: item.url, encoding: .utf8)
        let text = MeetingDocument.copyWithPrompt(markdown, prompt: try NotesPrompt.text())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
