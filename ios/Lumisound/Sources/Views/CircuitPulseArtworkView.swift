import SwiftUI

// MARK: - CircuitPulseArtworkView — "Circuit Pulse"
//
// The cover mounted like a chip on a dark circuit board: fixed traces etched
// around it, with a bright pulse of light continuously racing around the
// board's outer trace loop.
struct CircuitPulseArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    private var traceColor: Color { (palette?.primary ?? AppTheme.dynamicAccent).opacity(0.55) }
    private var pulseColor: Color { palette?.secondary ?? .cyan }

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let pulseProgress = ArtworkClock.loop(timeline.date, cycleDuration: 4.5)

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(red: 0.04, green: 0.07, blue: 0.05))

                // Fixed circuit traces: a simple rectangular loop with a few
                // right-angle branches — deterministic, drawn once per frame from
                // constants (cheap, no per-frame randomness).
                Canvas { context, size in
                    let inset: CGFloat = 34
                    let loop = Path(roundedRect: CGRect(x: inset, y: inset,
                                                         width: size.width - inset * 2,
                                                         height: size.height - inset * 2),
                                     cornerSize: CGSize(width: 10, height: 10))
                    context.stroke(loop, with: .color(traceColor), lineWidth: 2)

                    let branches: [(CGPoint, CGPoint)] = [
                        (CGPoint(x: inset, y: size.height * 0.3), CGPoint(x: inset - 20, y: size.height * 0.3)),
                        (CGPoint(x: size.width - inset, y: size.height * 0.7), CGPoint(x: size.width - inset + 20, y: size.height * 0.7)),
                        (CGPoint(x: size.width * 0.3, y: inset), CGPoint(x: size.width * 0.3, y: inset - 20)),
                        (CGPoint(x: size.width * 0.7, y: size.height - inset), CGPoint(x: size.width * 0.7, y: size.height - inset + 20)),
                    ]
                    for (a, b) in branches {
                        var p = Path()
                        p.move(to: a)
                        p.addLine(to: b)
                        context.stroke(p, with: .color(traceColor), lineWidth: 2)
                        context.fill(Path(ellipseIn: CGRect(x: b.x - 3, y: b.y - 3, width: 6, height: 6)),
                                     with: .color(traceColor))
                    }
                }
                .frame(width: 300, height: 300)

                // Traveling pulse, positioned along the same rounded-rect loop's
                // perimeter by walking its four straight edges in sequence.
                Circle()
                    .fill(pulseColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: pulseColor, radius: 8)
                    .position(pulsePosition(progress: pulseProgress, in: CGSize(width: 300, height: 300)))

                StyleCover(song: song, size: 190, cornerRadius: 16)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 20, y: 12)
                    .shadow(color: pulseColor.opacity(0.4), radius: 20)
            }
            .frame(width: 300, height: 300)
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 3.8))
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(.easeInOut(duration: 1.0), value: palette)
    }

    /// Walks the perimeter of the same inset rounded rect the traces are drawn
    /// on, `t` in 0...1 around the four straight edges (corners are treated as
    /// straight for simplicity — the tiny corner-radius error is invisible at
    /// this line width).
    private func pulsePosition(progress: CGFloat, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 34
        let left = inset, right = size.width - inset
        let top = inset, bottom = size.height - inset
        let perimeter = 2 * (right - left) + 2 * (bottom - top)
        let d = progress * perimeter

        if d < (right - left) {
            return CGPoint(x: left + d, y: top)
        } else if d < (right - left) + (bottom - top) {
            return CGPoint(x: right, y: top + (d - (right - left)))
        } else if d < 2 * (right - left) + (bottom - top) {
            return CGPoint(x: right - (d - (right - left) - (bottom - top)), y: bottom)
        } else {
            return CGPoint(x: left, y: bottom - (d - 2 * (right - left) - (bottom - top)))
        }
    }
}
