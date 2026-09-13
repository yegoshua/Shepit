import AppKit
import SwiftUI
import ShepitCore

/// The "Meetings" window. AppKit-hosted so it can be opened from the menu bar and from notifications alike.
@MainActor
final class MeetingsWindow: NSObject, NSWindowDelegate {
    let library: MeetingLibrary
    private var window: NSWindow?

    init(preferences: Preferences) {
        library = MeetingLibrary(preferences: preferences)
    }

    func show(selecting file: URL? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        library.startWatching()
        if let file { library.select(file) }
        // Shepit has no Dock icon, so bring the app forward or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        library.stopWatching()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Зустрічі"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 380)
        window.contentView = NSHostingView(rootView: MeetingsView(library: library).tint(Color.shepitAccent))
        window.center()
        window.setFrameAutosaveName("Meetings")
        window.delegate = self
        return window
    }
}

private struct MeetingsView: View {
    @ObservedObject var library: MeetingLibrary
    @State private var renaming: MeetingItem?
    @State private var newTitle = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $library.selection) {
                ForEach(library.items) { item in
                    MeetingRow(item: item)
                        .tag(item.url)
                        .contextMenu {
                            Button("Перейменувати…") { beginRename(item) }
                            Button("Показати у Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if library.items.isEmpty {
                    ContentUnavailableView {
                        Label("Зустрічей ще немає", systemImage: "person.2")
                    } description: {
                        Text("Записані зустрічі й Markdown-файли з папки зустрічей з’являться тут.")
                    } actions: {
                        Button("Відкрити папку") { openFolder() }
                    }
                }
            }
        } detail: {
            if let item = library.selectedItem {
                MeetingDetail(
                    item: item,
                    onCopy: { copy(item) },
                    onRename: { beginRename(item) }
                )
            } else {
                Text("Оберіть зустріч").foregroundStyle(.secondary)
            }
        }
        .alert("Перейменувати зустріч", isPresented: isRenaming, presenting: renaming) { item in
            TextField("Назва", text: $newTitle)
            Button("Перейменувати") { rename(item) }
            Button("Скасувати", role: .cancel) {}
        } message: { _ in
            Text("Файл буде перейменовано так само.")
        }
        .alert("Не вдалося", isPresented: hasError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var hasError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func beginRename(_ item: MeetingItem) {
        newTitle = item.title
        renaming = item
    }

    private func rename(_ item: MeetingItem) {
        do {
            try library.rename(item, to: newTitle)
        } catch {
            errorMessage = "Зустріч не перейменовано: \(error.localizedDescription)"
        }
    }

    private func copy(_ item: MeetingItem) -> Bool {
        do {
            try library.copyWithPrompt(item)
            return true
        } catch {
            errorMessage = "Не скопійовано: \(error.localizedDescription)"
            return false
        }
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.folder)
    }
}

private enum MeetingDateStyle {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "uk_UA")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct MeetingRow: View {
    let item: MeetingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).lineLimit(1)
            Text(MeetingDateStyle.formatter.string(from: item.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct MeetingDetail: View {
    let item: MeetingItem
    /// Returns whether the text reached the clipboard.
    let onCopy: () -> Bool
    let onRename: () -> Void
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("\(MeetingDateStyle.formatter.string(from: item.date)) · \(item.url.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
                MarkdownPreview(markdown: MeetingDocument.body(of: item.markdown))
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: copyWithPrompt) {
                    Label(copied ? "Скопійовано" : "Копіювати з промптом",
                          systemImage: copied ? "checkmark" : "doc.on.clipboard")
                }
                .help("Скопіювати промпт для нотаток разом із транскриптом — встав у будь-який чатбот")
                Button(action: onRename) { Label("Перейменувати", systemImage: "pencil") }
                    .help("Перейменувати зустріч і файл")
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                    Label("Показати у Finder", systemImage: "folder")
                }
            }
        }
        .onChange(of: item.url) { copied = false }
    }

    private func copyWithPrompt() {
        guard onCopy() else { return }
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Lightweight rendering of meeting Markdown: headings and inline emphasis, one paragraph per line.
private struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(line.dropFirst(3)).font(.headline).padding(.top, 10)
                } else if line.hasPrefix("# ") {
                    Text(line.dropFirst(2)).font(.title3.weight(.semibold)).padding(.top, 10)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(Self.inline(line)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}
