import AppKit
import SwiftUI
import ShepitCore

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var microphones: Microphones

    var body: some View {
        TabView {
            GeneralSettings(preferences: preferences)
                .tabItem { Label("Загальне", systemImage: "gearshape") }
            RecordingSettings(preferences: preferences, microphones: microphones)
                .tabItem { Label("Запис", systemImage: "mic") }
            MeetingSettings(preferences: preferences)
                .tabItem { Label("Зустрічі", systemImage: "person.2") }
        }
        .frame(width: 520)
        .tint(Color.shepitAccent)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                PillPreview(hotkey: preferences.hotkey, handsFree: preferences.handsFreeEnabled)
            }

            Section {
                Picker("Тема", selection: $preferences.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Гаряча клавіша", selection: $preferences.hotkey) {
                    ForEach(HotkeyKey.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $preferences.handsFreeEnabled) {
                    Text("Hands-free подвійним натисканням")
                    Text("Двічі натисни клавішу — запис іде без утримання.")
                }
            }

            Section {
                Toggle("Запускати при вході в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.set(enabled)
            launchError = LaunchAtLogin.needsApproval
                ? "Дозволь Shepit у System Settings → General → Login Items."
                : nil
        } catch {
            launchError = "Не вдалося змінити автозапуск: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

private struct RecordingSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var microphones: Microphones

    var body: some View {
        Form {
            Picker("Мікрофон", selection: $preferences.microphoneID) {
                Text("Системний").tag(String?.none)
                ForEach(microphones.available) { mic in
                    Text(mic.name).tag(String?.some(mic.id))
                }
                if let missingID {
                    Text("Недоступний пристрій").tag(String?.some(missingID))
                }
            }
            if missingID != nil {
                Label("Не підключено · використовується системний", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { microphones.refresh() }
    }

    /// The saved microphone when it isn't currently connected.
    private var missingID: String? {
        guard let id = preferences.microphoneID, !microphones.available.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

private struct MeetingSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            if !MeetingController.isSupported {
                Label(MeetingController.unsupportedReason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Гаряча клавіша зустрічі", selection: $preferences.meetingShortcut) {
                    ForEach(MeetingShortcut.allCases) { Text($0.title).tag($0) }
                }
                Picker("Мова зустрічей", selection: $preferences.meetingLanguageOverride) {
                    Text("Як для диктування · \(preferences.language.title)").tag(Language?.none)
                    ForEach(Language.allCases) { Text($0.title).tag(Language?.some($0)) }
                }
                LabeledContent("Папка зустрічей") {
                    HStack {
                        Text(preferences.meetingsFolder.path(percentEncoded: false)
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Змінити…", action: chooseFolder)
                    }
                }
                Text("Markdown-файли зустрічей зберігаються тут. Аудіо лишається в Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CallAppsSection(preferences: preferences)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.meetingsFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            preferences.meetingsFolder = url
        }
    }
}

/// The editable list of apps that make Shepit offer to record a call.
private struct CallAppsSection: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Section {
            ForEach(preferences.callApps) { app in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        preferences.callApps.removeAll { $0.id == app.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Прибрати зі списку")
                }
            }
            HStack {
                Button("Додати застосунок…", action: addApp)
                Spacer()
                if preferences.callApps != CallApp.defaults {
                    Button("Типовий список") { preferences.callApps = CallApp.defaults }
                }
            }
        } header: {
            Text("Пропонувати запис дзвінків")
        } footer: {
            Text("Коли один із цих застосунків почне використовувати мікрофон, Shepit запропонує записати зустріч. Запис почнеться лише після твоєї згоди.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  !preferences.callApps.contains(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame })
            else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            preferences.callApps.append(CallApp(name: name, bundleID: bundleID))
        }
    }
}

/// Static preview of the recording pill reflecting the chosen key and mode.
private struct PillPreview: View {
    let hotkey: HotkeyKey
    let handsFree: Bool

    private static let levels: [Float] = (0..<24).map { Float(0.35 + 0.55 * abs(sin(Double($0) * 1.7))) }

    var body: some View {
        RecordingPill(
            phase: .recording(handsFree: handsFree, startedAt: Date().addingTimeInterval(-6)),
            levels: Self.levels,
            stopKeySymbol: hotkey.symbol
        )
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
