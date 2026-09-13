import AppKit
import SwiftUI

enum OverlayPhase: Equatable {
    case recording(handsFree: Bool, startedAt: Date)
    case transcribing
    case success
    case failure(String)
}

/// Floating pill at the bottom center of the screen under the mouse cursor.
/// Never takes focus and lets clicks pass through.
@MainActor
final class RecordingOverlay {
    private static let size = CGSize(width: 320, height: 96)
    private static let bottomMargin: CGFloat = 28

    private let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show(_ phase: OverlayPhase) {
        hideWork?.cancel()
        if case .recording = phase, !isRecordingPhase(model.phase) { model.levels = OverlayModel.silence }
        withAnimation(.spring(duration: 0.3)) { model.phase = phase }

        if !panel.isVisible {
            place()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        switch phase {
        case .success: hide(after: 0.8)
        case .failure: hide(after: 1.5)
        case .recording, .transcribing: break
        }
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) { [panel] in
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }

    /// Feeds a normalized (0...1) microphone level into the waveform.
    func push(level: Float) {
        model.levels.removeFirst()
        model.levels.append(level)
    }

    private func hide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + Self.bottomMargin))
    }

    private func isRecordingPhase(_ phase: OverlayPhase?) -> Bool {
        if case .recording = phase { true } else { false }
    }
}

@MainActor
private final class OverlayModel: ObservableObject {
    static let barCount = 36
    static let silence = [Float](repeating: 0, count: barCount)

    @Published var phase: OverlayPhase?
    @Published var levels = silence
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let phase = model.phase {
                pill(for: phase)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    .environment(\.colorScheme, .dark)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pill(for phase: OverlayPhase) -> some View {
        switch phase {
        case .recording(let handsFree, let startedAt):
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .phaseAnimator([1.0, 0.35]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.7) }
                    Waveform(levels: model.levels)
                        .frame(width: 150, height: 28)
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.format(context.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    if handsFree {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                if handsFree {
                    Text("⌥ стоп · esc скасувати")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Розпізнаю…").foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .medium))

        case .success:
            Label("Скопійовано", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white, .green)

        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white, .yellow)
                .lineLimit(1)
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Scrolling bars: newest level on the right, older levels move left.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.4 + 0.6 * Double(index) / Double(levels.count)))
                    .frame(width: 2, height: max(2, CGFloat(levels[index]) * 28))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}
