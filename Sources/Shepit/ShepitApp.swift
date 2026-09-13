import SwiftUI

@main
struct ShepitApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state, preferences: state.preferences)
        } label: {
            Image(systemName: state.status.symbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(preferences: state.preferences, microphones: state.microphones)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var preferences: Preferences
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shepit").font(.headline)

            Label(state.status.title, systemImage: state.status.symbol)
                .foregroundStyle(state.status.isError ? .red : .primary)

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Picker("Мова", selection: $preferences.language) {
                ForEach(Language.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Звуки", isOn: $preferences.soundsEnabled)

            if !state.lastText.isEmpty {
                Divider()
                Text("Останнє:").font(.caption).foregroundStyle(.secondary)
                Text(state.lastText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if !state.hasAccessibility {
                Button("Надати доступ Accessibility…") { state.requestAccessibility() }
            }
            Button("Налаштування…") {
                // Shepit has no Dock icon, so bring the app forward or the window opens behind others.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")
            Button("Вийти") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        .tint(Palette.jade)
    }

    private var helpText: AttributedString {
        let key = preferences.hotkey.title.lowercased()
        var text = "Тримай **\(key)**, говори, відпусти — текст вставиться в активне поле й лишиться в буфері."
        if preferences.handsFreeEnabled {
            text += "\nНатисни **двічі** — запис без утримання, \(preferences.hotkey.symbol) щоб зупинити, esc щоб скасувати."
        }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
