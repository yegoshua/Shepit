import SwiftUI

@main
struct ShepitApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state, preferences: state.preferences, overlay: state.overlayModel, meeting: state.meeting)
        } label: {
            MenuBarLabel(state: state, meeting: state.meeting)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(preferences: state.preferences, microphones: state.microphones)
        }
    }
}

/// Microphone icon normally; a filled jade timer capsule while dictating (design 5b/6b)
/// and a red one while a meeting is being recorded.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var meeting: MeetingController

    var body: some View {
        if state.status == .recording {
            Image(nsImage: TimerCapsule.image(text: TimerLabel.format(TimeInterval(state.elapsedSeconds))))
        } else if meeting.isRecording {
            Image(nsImage: TimerCapsule.meetingImage(text: TimerLabel.format(TimeInterval(meeting.elapsedSeconds))))
        } else if meeting.isProcessing && !meeting.isRecording && state.status == .idle {
            Image(systemName: "waveform")
        } else {
            Image(systemName: state.status == .idle ? "mic" : state.status.symbol)
        }
    }
}

private enum TimerCapsule {
    static func image(text: String) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill = dark
            ? NSColor(srgbRed: 0x38 / 255, green: 0xD6 / 255, blue: 0x9A / 255, alpha: 0.9)
            : NSColor(srgbRed: 0x0F / 255, green: 0x8F / 255, blue: 0x5F / 255, alpha: 1)
        let ink = dark ? NSColor(srgbRed: 0x08 / 255, green: 0x15 / 255, blue: 0x0F / 255, alpha: 1) : .white
        return image(text: text, fill: fill, ink: ink)
    }

    /// Red dot on a neutral capsule, so a meeting reads as "recording" without looking like dictation.
    static func meetingImage(text: String) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return image(text: text, fill: (dark ? NSColor.white : .black).withAlphaComponent(0.12),
                     ink: dark ? .white : .black, dot: .systemRed)
    }

    private static func image(text: String, fill: NSColor, ink: NSColor, dot: NSColor? = nil) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: ink,
        ]
        let label = NSAttributedString(string: text, attributes: attributes)
        let size = NSSize(width: 8 + 5 + 6 + ceil(label.size().width) + 8, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            (dot ?? ink).setFill()
            NSBezierPath(ovalIn: NSRect(x: 8, y: (rect.height - 5) / 2, width: 5, height: 5)).fill()
            label.draw(at: NSPoint(x: 19, y: (rect.height - label.size().height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var preferences: Preferences
    @ObservedObject var overlay: OverlayModel
    @ObservedObject var meeting: MeetingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme

    private var theme: Theme { .of(colorScheme) }
    private var isRecording: Bool { state.status == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Shepit").font(.system(size: 13, weight: .semibold)).tracking(-0.1)
                Spacer()
                StatusChip(status: state.status, theme: theme)
            }
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 5, trailing: 10))

            if isRecording {
                recordingStrip
            } else {
                Text(helpText)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 2, leading: 10, bottom: 8, trailing: 10))
            }

            MenuDivider()

            if isRecording {
                MenuRow("Зупинити запис", shortcut: preferences.hotkey.symbol) { state.stopRecordingFromMenu() }
                MenuRow("Скасувати", shortcut: "esc") { state.cancelRecordingFromMenu() }
                MenuDivider()
                HStack {
                    Text("Мова").font(.system(size: 13))
                    Spacer()
                    Text(preferences.language.title).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .opacity(0.45)
            } else {
                HStack(spacing: 8) {
                    Text("Мова").font(.system(size: 13))
                    Spacer()
                    Picker("Мова", selection: $preferences.language) {
                        ForEach(Language.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)

                Toggle("Звуки", isOn: $preferences.soundsEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)

                MenuDivider()
            }

            meetingRows
            MenuRow("Зустрічі…") { state.meetingsWindow.show() }
            MenuDivider()

            if !state.hasAccessibility {
                MenuRow("Надати доступ Accessibility…") { state.requestAccessibility() }
            }
            MenuRow("Налаштування…", shortcut: "⌘,") {
                // Shepit has no Dock icon, so bring the app forward or the window opens behind others.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")
            if !isRecording && meeting.phase == .idle && !meeting.isProcessing {
                MenuRow("Вийти", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(4)
        .frame(width: 272)
        .tint(Color.shepitAccent)
    }

    @ViewBuilder
    private var meetingRows: some View {
        let shortcut = preferences.meetingShortcut == .none ? nil : preferences.meetingShortcut.symbol
        if !MeetingController.isSupported {
            MenuNote(title: "Записати зустріч", detail: MeetingController.unsupportedReason)
        } else {
            switch meeting.phase {
            case .idle:
                if case .record(let app) = meeting.offer {
                    MenuNote(title: "Дзвінок у \(app)", detail: "Записати цю зустріч?")
                }
                MenuRow("Записати зустріч", shortcut: shortcut) { meeting.start() }
                if case .record = meeting.offer {
                    MenuRow("Не записувати") { meeting.dismissOffer() }
                }
            case .recording:
                if meeting.stillRecordingPrompt != nil {
                    // Same question as the notification, for when notifications are off or dismissed.
                    MenuNote(title: "Зустріч ще записується?", detail: nil)
                    MenuRow("Так, продовжити") { meeting.answerStillRecording(true) }
                }
                if case .stop(let app) = meeting.offer {
                    MenuNote(title: "Дзвінок у \(app) завершився?", detail: "\(app) більше не використовує мікрофон.")
                    MenuRow("Продовжити запис") { meeting.dismissOffer() }
                }
                MenuRow("Зупинити зустріч · \(TimerLabel.format(TimeInterval(meeting.elapsedSeconds)))", shortcut: shortcut) {
                    meeting.stop()
                }
            case .preparing:
                MenuNote(title: "Готую запис зустрічі…", detail: nil)
            }
            if meeting.isProcessing {
                MenuNote(title: processingTitle, detail: meeting.isRecording ? "Продовжу після зупинки запису." : nil)
            }
            if let warning = meeting.othersWarning {
                Label(warning, systemImage: "speaker.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 3, trailing: 10))
                MenuRow("Дозволити запис системного звуку…") {
                    NSWorkspace.shared.open(MeetingController.privacySettingsURL)
                }
            }
            if let error = meeting.lastError, meeting.phase == .idle {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 5, trailing: 10))
            }
        }
    }

    private var processingTitle: String {
        let waiting = meeting.processingCount - 1
        let base = meeting.isRecording ? "Розшифровка на паузі" : "Розшифровую зустріч…"
        return waiting > 0 ? "\(base) · ще \(waiting) в черзі" : base
    }

    private var recordingStrip: some View {
        HStack(spacing: 12) {
            Waveform(levels: overlay.levels,
                     style: AnyShapeStyle(colorScheme == .dark ? Color.white.opacity(0.75) : Color.black.opacity(0.55)),
                     barWidth: 2.5, maxHeight: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimerLabel(startedAt: state.recordingStartedAt)
                .font(.system(size: 12.5, design: .monospaced).monospacedDigit())
            if state.isHandsFree {
                LockGlyph()
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(width: 10, height: 12)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
    }

    private var helpText: AttributedString {
        let key = preferences.hotkey.title.lowercased()
        var text = "Тримай \(key), говори, відпусти — текст вставиться в активне поле й лишиться в буфері."
        if preferences.handsFreeEnabled {
            text += " Натисни двічі — запис без утримання, \(preferences.hotkey.symbol) щоб зупинити, esc щоб скасувати."
        }
        var attributed = AttributedString(text)
        if let range = attributed.range(of: key) { attributed[range].foregroundColor = .primary }
        return attributed
    }
}

private struct StatusChip: View {
    let status: Status
    let theme: Theme

    var body: some View {
        HStack(spacing: 5) {
            TimelineView(.animation(paused: !pulses)) { context in
                let p = pulses ? (1 + cos(2 * .pi * context.date.timeIntervalSinceReferenceDate / 1.6)) / 2 : 1
                Circle().fill(dotColor).frame(width: 5, height: 5).opacity(0.45 + 0.55 * p)
            }
            .frame(width: 5, height: 5)
            Text(title).lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(textColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(dotColor.opacity(0.14), in: Capsule())
    }

    private var pulses: Bool { status == .recording || status == .transcribing }
    private var dotColor: Color { status.isError ? theme.warning : theme.accent }
    private var textColor: Color { status.isError ? theme.warning : theme.chipText }

    private var title: String {
        switch status {
        case .recording: "Запис"
        case .loadingModel(let detail): detail.replacingOccurrences(of: "Модель: ", with: "")
        case .failure, .error: "Помилка"
        default: status.title
        }
    }
}

private struct MenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.1))
            .frame(height: 0.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
    }
}

/// Inactive menu line with an optional explanation underneath.
private struct MenuNote: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// Menu item with a hover highlight and a right-aligned shortcut hint.
private struct MenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.system(size: 12.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(.primary.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
