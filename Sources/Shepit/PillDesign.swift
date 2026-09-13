import AppKit
import SwiftUI

// Claude Design "Recording Pill": 4a/4b (dark, "obsidian & jade"), 6c (light), 5/6 (menu).

/// Colors shared by the pill, the menu and settings, resolved per appearance.
struct Theme {
    let accent: Color
    let chipText: Color
    let lockGlyph: Color
    let warning: Color
    let text: Color
    let secondaryText: Color
    let divider: Color

    // Pill surface
    let pillFill: [Color]
    let pillFillAccented: [Color]
    let pillBorder: Color
    let pillBorderAccentOpacity: Double
    let topHighlight: Color
    let bottomEdge: Color
    let shadow: Color
    let shadowRadius: CGFloat
    let shadowY: CGFloat
    let glowOpacity: Double

    // Ring
    let ringCore: Color
    /// Dark holds on a brushed-metal rim; light uses a thin track with a spinning jade arc.
    let metalHoldRing: Bool
    let ringTrack: Color
    let accentConicTail: Color
    let processingArc: Color

    // Wave
    let waveHold: AnyShapeStyle
    let waveHoldOpacity: Double
    let waveLocked: AnyShapeStyle

    static let dark = Theme(
        accent: Color(rgb: 0x38D69A),
        chipText: Color(rgb: 0x8FE8C2),
        lockGlyph: Color(rgb: 0xBFF0D9),
        warning: Color(rgb: 0xE8B25C),
        text: Color(rgb: 0xF2F7F4),
        secondaryText: Color(rgb: 0x7F8B86),
        divider: .white.opacity(0.09),
        pillFill: [Color(rgb: 0x1E2220, alpha: 0.96), Color(rgb: 0x0F1110, alpha: 0.96)],
        pillFillAccented: [Color(rgb: 0x1F2622, alpha: 0.96), Color(rgb: 0x0E1110, alpha: 0.96)],
        pillBorder: .white.opacity(0.07),
        pillBorderAccentOpacity: 0.16,
        topHighlight: .white.opacity(0.07),
        bottomEdge: .black.opacity(0.6),
        shadow: .black.opacity(0.85),
        shadowRadius: 22,
        shadowY: 16,
        glowOpacity: 0.16,
        ringCore: Color(rgb: 0x121514),
        metalHoldRing: true,
        ringTrack: .white.opacity(0.1),
        accentConicTail: .white.opacity(0.35),
        processingArc: Color(rgb: 0x8FE8C2),
        waveHold: AnyShapeStyle(Color(rgb: 0xEBF2EE, alpha: 0.55)),
        waveHoldOpacity: 1,
        waveLocked: AnyShapeStyle(LinearGradient(colors: [.white, Color(rgb: 0xCFE9DD)], startPoint: .top, endPoint: .bottom))
    )

    static let light = Theme(
        accent: Color(rgb: 0x0F8F5F),
        chipText: Color(rgb: 0x0B7A51),
        lockGlyph: Color(rgb: 0x0B7A51),
        warning: Color(rgb: 0xB7791F),
        text: Color(rgb: 0x1C1C1E),
        secondaryText: Color(rgb: 0x6B6B70),
        divider: .black.opacity(0.1),
        pillFill: [.white.opacity(0.86), .white.opacity(0.86)],
        pillFillAccented: [.white.opacity(0.92), .white.opacity(0.92)],
        pillBorder: .black.opacity(0.08),
        pillBorderAccentOpacity: 0.28,
        topHighlight: .white.opacity(0.9),
        bottomEdge: .clear,
        shadow: Color(rgb: 0x14181E, alpha: 0.3),
        shadowRadius: 14,
        shadowY: 10,
        glowOpacity: 0.22,
        ringCore: .white,
        metalHoldRing: false,
        ringTrack: .black.opacity(0.1),
        accentConicTail: .black.opacity(0.06),
        processingArc: Color(rgb: 0x0F8F5F),
        waveHold: AnyShapeStyle(LinearGradient(colors: [Color(rgb: 0x5C6360), Color(rgb: 0x11241C)], startPoint: .top, endPoint: .bottom)),
        waveHoldOpacity: 0.5,
        waveLocked: AnyShapeStyle(LinearGradient(colors: [Color(rgb: 0x5C6360), Color(rgb: 0x11241C)], startPoint: .top, endPoint: .bottom))
    )

    static func of(_ scheme: ColorScheme) -> Theme { scheme == .dark ? .dark : .light }
}

extension Color {
    /// Jade accent that follows the current appearance (for tints of native controls).
    static let shepitAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x38 / 255, green: 0xD6 / 255, blue: 0x9A / 255, alpha: 1)
            : NSColor(srgbRed: 0x0F / 255, green: 0x8F / 255, blue: 0x5F / 255, alpha: 1)
    })

    init(rgb: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Pill

struct RecordingPill: View {
    let phase: OverlayPhase
    let levels: [Float]
    let stopKeySymbol: String

    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { .of(colorScheme) }

    var body: some View {
        HStack(spacing: 20) {
            StateRing(style: ringStyle, theme: theme)
            HStack(spacing: 18) { content }
        }
        .padding(.leading, 12)
        .padding(.trailing, 28)
        .padding(.vertical, 12)
        .background(PillBackground(accented: isAccented, tint: glowTint, theme: theme))
        .animation(.spring(duration: 0.35), value: ringStyle)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .recording(let handsFree, let startedAt):
            Waveform(levels: levels, style: handsFree ? theme.waveLocked : theme.waveHold,
                     barWidth: 3, maxHeight: 28)
                .opacity(handsFree ? 1 : theme.waveHoldOpacity)
            TimerLabel(startedAt: startedAt)
                .font(.system(size: 15, design: .monospaced).monospacedDigit())
                .tracking(0.6)
                .foregroundStyle(theme.text)
            if handsFree {
                Rectangle().fill(theme.divider).frame(width: 1, height: 16)
                Text("\(stopKeySymbol) СТОП")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }
        case .transcribing:
            caption("розшифровка…", color: theme.secondaryText)
        case .success:
            caption("скопійовано", color: theme.text)
        case .failure(let message):
            caption(message, color: theme.text.opacity(0.8))
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
    private var glowTint: Color { ringStyle == .failure ? theme.warning : theme.accent }
}

/// Glass capsule: fill, hairline top highlight, bottom edge, soft shadow and a faint halo when accented.
private struct PillBackground: View {
    let accented: Bool
    let tint: Color
    let theme: Theme

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: accented ? theme.pillFillAccented : theme.pillFill,
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Capsule().strokeBorder(
                accented ? tint.opacity(theme.pillBorderAccentOpacity) : theme.pillBorder, lineWidth: 1
            ))
            .overlay(Capsule().inset(by: 1).strokeBorder(LinearGradient(
                stops: [
                    .init(color: theme.topHighlight, location: 0),
                    .init(color: .clear, location: 0.12),
                    .init(color: .clear, location: 0.88),
                    .init(color: theme.bottomEdge, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 1))
            .shadow(color: theme.shadow, radius: theme.shadowRadius, y: theme.shadowY)
            .shadow(color: tint.opacity(accented ? theme.glowOpacity : 0), radius: 14)
    }
}

/// 44pt ring carrying the state.
private struct StateRing: View {
    enum Style: Equatable { case hold, locked, processing, success, failure }

    let style: Style
    let theme: Theme

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                rim(t)
                if let arc = arcColor {
                    Circle()
                        .inset(by: 0.75)
                        .trim(from: 0, to: style == .processing ? 0.22 : 0.25)
                        .stroke(arc, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(spin(t, period: style == .processing ? 1.1 : 3.4) - 90))
                }
                glyph(t)
            }
        }
        .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private func rim(_ t: TimeInterval) -> some View {
        switch style {
        case .hold where theme.metalHoldRing, .processing where theme.metalHoldRing:
            Circle().fill(Self.conic(from: 200, [
                (.white.opacity(0.28), 0), (.white.opacity(0.04), 0.35),
                (.white.opacity(0.02), 0.65), (.white.opacity(0.22), 1),
            ]))
            Circle().inset(by: 1).fill(theme.ringCore)
        case .hold, .processing:
            Circle().fill(theme.ringCore)
            Circle().inset(by: 0.75).stroke(theme.ringTrack, lineWidth: 1.5)
        case .locked, .success, .failure:
            let color = style == .failure ? theme.warning : theme.accent
            Circle()
                .fill(Self.conic(from: 0, [
                    (color.opacity(0.9), 0), (color.opacity(0.06), 0.58),
                    (theme.accentConicTail, 0.88), (color.opacity(0.9), 1),
                ]))
                .rotationEffect(.degrees(style == .locked ? spin(t, period: 4.2) : 0))
            Circle().inset(by: 1.2).fill(theme.ringCore)
        }
    }

    /// Light theme's hold ring and every processing ring show a spinning arc.
    private var arcColor: Color? {
        switch style {
        case .processing: theme.processingArc
        case .hold where !theme.metalHoldRing: theme.accent
        default: nil
        }
    }

    @ViewBuilder
    private func glyph(_ t: TimeInterval) -> some View {
        switch style {
        case .hold:
            // Breathing: opacity 1 → .45, scale 1 → .82.
            let p = (1 + cos(2 * .pi * t / 2)) / 2
            Circle()
                .fill(theme.accent)
                .frame(width: 8, height: 8)
                .shadow(color: theme.accent.opacity(theme.metalHoldRing ? 0.45 : 0), radius: 5)
                .opacity(0.45 + 0.55 * p)
                .scaleEffect(0.82 + 0.18 * p)
        case .locked:
            LockGlyph()
                .stroke(theme.lockGlyph, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(width: 12, height: 14)
        case .processing:
            EmptyView()
        case .success:
            CheckGlyph()
                .stroke(theme.lockGlyph, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 14)
        case .failure:
            Text("!")
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.warning)
        }
    }

    /// CSS `conic-gradient(from Xdeg, …)` starts at 12 o'clock; SwiftUI angles start at 3 o'clock.
    private static func conic(from degrees: Double, _ stops: [(Color, CGFloat)]) -> AngularGradient {
        AngularGradient(stops: stops.map { .init(color: $0.0, location: $0.1) }, center: .center,
                        startAngle: .degrees(degrees - 90), endAngle: .degrees(degrees + 270))
    }

    private func spin(_ t: TimeInterval, period: Double) -> Double {
        t.truncatingRemainder(dividingBy: period) / period * 360
    }
}

/// Padlock from the design's 12×14 SVG: body rect (1,6,10,7, r2) + shackle arc.
struct LockGlyph: Shape {
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

/// Bars from live microphone levels, shaped by the design's center falloff.
struct Waveform: View {
    let levels: [Float]
    let style: AnyShapeStyle
    let barWidth: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(style)
                    .frame(width: barWidth, height: height(at: index))
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func height(at index: Int) -> CGFloat {
        let center = Double(levels.count - 1) / 2
        let falloff = 0.45 + 0.55 * (1 - abs(Double(index) - center) / (center + 1))
        return max(2.5, maxHeight * CGFloat(levels[index]) * falloff)
    }
}

struct TimerLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(startedAt)))
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
