import SwiftUI

@main
struct ShepitApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.status.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shepit").font(.headline)

            Label(state.status.title, systemImage: state.status.symbol)
                .foregroundStyle(state.status.isError ? .red : .primary)

            Text("Тримай **правий ⌥ Option**, говори, відпусти — текст вставиться в активне поле.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Picker("Мова", selection: $state.language) {
                ForEach(Language.allCases) { Text($0.title).tag($0) }
            }

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
            Button("Вийти") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
    }
}
