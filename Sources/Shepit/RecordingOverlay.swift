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
    private static let size = CGSize(width: 480, height: 140)
    private static let bottomMargin: CGFloat = 4

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
    static let barCount = 24
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
                RecordingPill(phase: phase, levels: model.levels)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.bottom, 36) // room for the drop shadow
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Design: "Obsidian & jade" (Claude Design, Recording Pill 4a/4b)

private enum Palette {
    static let jade = Color(rgb: 0x38D69A)
    static let mint = Color(rgb: 0xBFF0D9)
    static let amber = Color(rgb: 0xE8B25C)
    static let ringCore = Color(rgb: 0x121514)
    static let timer = Color(rgb: 0xE9EFEC)
    static let timerLocked = Color(rgb: 0xF2F7F4)
    static let caption = Color(rgb: 0x7F8B86)
    static let processing = Color(rgb: 0xB9B9C1)
    static let processingArc = Color(rgb: 0x8FE8C2)
}

private struct RecordingPill: View {
    let phase: OverlayPhase
    let levels: [Float]

    var body: some View {
        HStack(spacing: 20) {
            StateRing(style: ringStyle)
            HStack(spacing: 18) { content }
        }
        .padding(.leading, 12)
        .padding(.trailing, 28)
        .padding(.vertical, 12)
        .background(PillBackground(glowing: isAccented, tint: glowTint))
        .animation(.spring(duration: 0.35), value: ringStyle)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .recording(let handsFree, let startedAt):
            Waveform(levels: levels, locked: handsFree)
            TimerLabel(startedAt: startedAt, locked: handsFree)
            if handsFree {
                Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 16)
                Text("⌥ СТОП")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Palette.caption)
                    .fixedSize(horizontal: true, vertical: false)
            }
        case .transcribing:
            caption("розшифровка…", color: Palette.processing)
        case .success:
            caption("скопійовано", color: Palette.timer)
        case .failure(let message):
            caption(message, color: Palette.timer.opacity(0.8))
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 14, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var ringStyle: StateRing.Style {
        switch phase {
        case .recording(let handsFree, _): handsFree ? .locked : .hold
        case .transcribing: .processing
        case .success: .success
        case .failure: .failure
        }
    }

    private var isAccented: Bool { ringStyle == .locked || ringStyle == .success || ringStyle == .failure }
    private var glowTint: Color { ringStyle == .failure ? Palette.amber : Palette.jade }
}

/// Deep glass capsule: vertical gradient, hairline top highlight, dark bottom edge,
/// and a faint colored halo only in accented states.
private struct PillBackground: View {
    let glowing: Bool
    let tint: Color

    var body: some View {
        Capsule()
            .fill(LinearGradient(
                colors: glowing
                    ? [Color(rgb: 0x1F2622, alpha: 0.96), Color(rgb: 0x0E1110, alpha: 0.96)]
                    : [Color(rgb: 0x1E2220, alpha: 0.96), Color(rgb: 0x0F1110, alpha: 0.96)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(Capsule().strokeBorder(
                glowing ? tint.opacity(0.16) : .white.opacity(0.07), lineWidth: 1
            ))
            .overlay(Capsule().inset(by: 1).strokeBorder(LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.07), location: 0),
                    .init(color: .clear, location: 0.12),
                    .init(color: .clear, location: 0.88),
                    .init(color: .black.opacity(0.6), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 1))
            .shadow(color: .black.opacity(0.85), radius: 22, y: 16)
            .shadow(color: tint.opacity(glowing ? 0.16 : 0), radius: 14)
    }
}

/// 44pt ring carrying the state: brushed metal while holding, spinning jade when locked.
private struct StateRing: View {
    enum Style: Equatable { case hold, locked, processing, success, failure }

    let style: Style

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(rimGradient)
                    .rotationEffect(.degrees(style == .locked ? spin(t, period: 4.2) : 0))
                Circle().inset(by: style == .locked ? 1.2 : 1).fill(Palette.ringCore)
                if style == .processing {
                    Circle()
                        .inset(by: 0.75)
                        .trim(from: 0, to: 0.22)
                        .stroke(Palette.processingArc, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(spin(t, period: 1.1) - 90))
                }
                glyph(t)
            }
        }
        .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private func glyph(_ t: TimeInterval) -> some View {
        switch style {
        case .hold:
            // 2 s breathing: opacity 1 → .45, scale 1 → .82.
            let p = (1 + cos(2 * .pi * t / 2)) / 2
            Circle()
                .fill(Palette.jade)
                .frame(width: 8, height: 8)
                .shadow(color: Palette.jade.opacity(0.45), radius: 5)
                .opacity(0.45 + 0.55 * p)
                .scaleEffect(0.82 + 0.18 * p)
        case .locked:
            LockGlyph()
                .stroke(Palette.mint, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(width: 12, height: 14)
        case .processing:
            EmptyView()
        case .success:
            CheckGlyph()
                .stroke(Palette.mint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 14)
        case .failure:
            Text("!")
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.amber)
        }
    }

    /// CSS `conic-gradient(from Xdeg, …)` starts at 12 o'clock; SwiftUI angles start at 3 o'clock.
    private var rimGradient: AngularGradient {
        func conic(from degrees: Double, _ stops: [Gradient.Stop]) -> AngularGradient {
            AngularGradient(stops: stops, center: .center,
                            startAngle: .degrees(degrees - 90), endAngle: .degrees(degrees + 270))
        }
        switch style {
        case .hold, .processing:
            return conic(from: 200, [
                .init(color: .white.opacity(0.28), location: 0),
                .init(color: .white.opacity(0.04), location: 0.35),
                .init(color: .white.opacity(0.02), location: 0.65),
                .init(color: .white.opacity(0.22), location: 1),
            ])
        case .locked, .success:
            return conic(from: 0, [
                .init(color: Palette.jade.opacity(0.9), location: 0),
                .init(color: Palette.jade.opacity(0.05), location: 0.55),
                .init(color: .white.opacity(0.35), location: 0.88),
                .init(color: Palette.jade.opacity(0.9), location: 1),
            ])
        case .failure:
            return conic(from: 0, [
                .init(color: Palette.amber.opacity(0.85), location: 0),
                .init(color: Palette.amber.opacity(0.05), location: 0.55),
                .init(color: .white.opacity(0.3), location: 0.88),
                .init(color: Palette.amber.opacity(0.85), location: 1),
            ])
        }
    }

    private func spin(_ t: TimeInterval, period: Double) -> Double {
        t.truncatingRemainder(dividingBy: period) / period * 360
    }
}

/// Padlock from the design's 12×14 SVG: body rect (1,6,10,7, r2) + shackle arc.
private struct LockGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 12, sy = rect.height / 14
        var path = Path(roundedRect: CGRect(x: 1 * sx, y: 6 * sy, width: 10 * sx, height: 7 * sy),
                        cornerRadius: 2 * sx)
        path.move(to: CGPoint(x: 3.6 * sx, y: 6 * sy))
        path.addLine(to: CGPoint(x: 3.6 * sx, y: 4.2 * sy))
        path.addArc(center: CGPoint(x: 6 * sx, y: 4.2 * sy), radius: 2.4 * sx,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: 8.4 * sx, y: 6 * sy))
        return path
    }
}

private struct CheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 12, sy = rect.height / 14
        var path = Path()
        path.move(to: CGPoint(x: 1.5 * sx, y: 7.5 * sy))
        path.addLine(to: CGPoint(x: 4.8 * sx, y: 10.5 * sy))
        path.addLine(to: CGPoint(x: 10.5 * sx, y: 3.5 * sy))
        return path
    }
}

/// 24 hairline bars from live microphone levels, shaped by the design's center falloff.
private struct Waveform: View {
    let levels: [Float]
    let locked: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(locked
                          ? AnyShapeStyle(LinearGradient(colors: [.white, Color(rgb: 0xCFE9DD)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color(rgb: 0xEBF2EE, alpha: 0.55)))
                    .frame(width: 3, height: height(at: index))
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func height(at index: Int) -> CGFloat {
        let center = Double(levels.count - 1) / 2
        let falloff = 0.45 + 0.55 * (1 - abs(Double(index) - center) / (center + 1))
        return max(2.5, 28 * CGFloat(levels[index]) * falloff)
    }
}

private struct TimerLabel: View {
    let startedAt: Date
    let locked: Bool

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(startedAt)))
                .font(.system(size: 15, design: .monospaced).monospacedDigit())
                .tracking(0.6)
                .foregroundStyle(locked ? Palette.timerLocked : Palette.timer)
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension Color {
    init(rgb: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: alpha)
    }
}
