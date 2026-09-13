import AppKit
import SwiftUI
import ShepitCore

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
    private static let size = CGSize(width: 480, height: 140)
    private static let bottomMargin: CGFloat = 4

    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    /// Called once the pill has fully faded out.
    var onHide: (() -> Void)?

    /// Symbol of the push-to-talk key shown in the hands-free stop hint.
    var stopKeySymbol: String {
        get { model.stopKeySymbol }
        set { model.stopKeySymbol = newValue }
    }

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
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // A new recording may start while the previous pill is still fading out on another screen.
        if case .recording = phase { place() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        switch phase {
        case .success: hide(after: 0.8)
        case .failure: hide(after: 1.5)
        case .recording, .transcribing: break
        }
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                self.onHide?()
            }
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
final class OverlayModel: ObservableObject {
    static let barCount = 24
    static let silence = [Float](repeating: 0, count: barCount)

    @Published var phase: OverlayPhase?
    @Published var levels = silence
    @Published var stopKeySymbol = HotkeyKey.rightOption.symbol
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let phase = model.phase {
                RecordingPill(phase: phase, levels: model.levels, stopKeySymbol: model.stopKeySymbol)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.bottom, 36) // room for the drop shadow
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
