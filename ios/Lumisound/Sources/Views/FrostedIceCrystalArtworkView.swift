import SwiftUI

// MARK: - FrostedIceCrystalArtworkView — "Frosted Ice Crystal"
//
// Fern-like frost needles creep in from the corners and slowly retreat again,
// like ice forming on a cold window, around a cover lit in cool blue-white.
struct FrostedIceCrystalArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    /// Each frost needle: a start point near an edge/corner, a direction unit
    /// vector pointing inward, a max length, and a few side-branch angles —
    /// all fixed/deterministic, only `growth` (0...1) animates.
    private struct Needle {
        let start: CGPoint
        let dx: CGFloat
        let dy: CGFloat
        let length: CGFloat
    }

    private let needles: [Needle] = [
        Needle(start: CGPoint(x: 10, y: 10), dx: 1, dy: 0.6, length: 90),
        Needle(start: CGPoint(x: 10, y: 10), dx: 0.6, dy: 1, length: 70),
        Needle(start: CGPoint(x: 290, y: 10), dx: -1, dy: 0.6, length: 90),
        Needle(start: CGPoint(x: 290, y: 10), dx: -0.6, dy: 1, length: 70),
        Needle(start: CGPoint(x: 10, y: 290), dx: 1, dy: -0.6, length: 90),
        Needle(start: CGPoint(x: 10, y: 290), dx: 0.6, dy: -1, length: 70),
        Needle(start: CGPoint(x: 290, y: 290), dx: -1, dy: -0.6, length: 90),
        Needle(start: CGPoint(x: 290, y: 290), dx: -0.6, dy: -1, length: 70),
        Needle(start: CGPoint(x: 150, y: 6), dx: 0, dy: 1, length: 50),
        Needle(start: CGPoint(x: 150, y: 294), dx: 0, dy: -1, length: 50),
    ]

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let growth = 0.3 + 0.7 * ArtworkClock.pingPong(timeline.date, legDuration: 4.2)

            ZStack {
                StyleCover(song: song, size: 300, cornerRadius: 20)
                    .clipShape(shape)

                LinearGradient(
                    colors: [Color(red: 0.75, green: 0.9, blue: 1.0).opacity(0.35), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .clipShape(shape)

                Canvas { context, _ in
                    for needle in needles {
                        drawBranch(context: context, needle: needle, growth: growth, scale: 1.0)
                        drawBranch(context: context, needle: needle, growth: growth, scale: 0.6, sideways: true)
                    }
                }
                .frame(width: 300, height: 300)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
            }
            .frame(width: 300, height: 300)
            .clipShape(shape)
            .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
            .shadow(color: Color(red: 0.6, green: 0.85, blue: 1.0).opacity(0.35), radius: 24)
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 3.6))
    }

    /// Draws one straight needle (or, for `sideways`, a shorter offshoot at a
    /// perpendicular angle from its midpoint) from `start` toward
    /// `start + (dx,dy) * length * growth`.
    private func drawBranch(context: GraphicsContext, needle: Needle, growth: CGFloat, scale: CGFloat, sideways: Bool = false) {
        let end = CGPoint(
            x: needle.start.x + needle.dx * needle.length * growth * scale,
            y: needle.start.y + needle.dy * needle.length * growth * scale
        )
        var path = Path()
        path.move(to: needle.start)
        path.addLine(to: end)
        context.stroke(path, with: .color(.white.opacity(0.5 * Double(growth))), lineWidth: sideways ? 1 : 1.5)

        if sideways {
            // A perpendicular offshoot from the midpoint, for a fern-like look.
            let mid = CGPoint(x: (needle.start.x + end.x) / 2, y: (needle.start.y + end.y) / 2)
            let perp = CGPoint(x: -needle.dy, y: needle.dx)
            let branchEnd = CGPoint(x: mid.x + perp.x * 18 * growth, y: mid.y + perp.y * 18 * growth)
            var branchPath = Path()
            branchPath.move(to: mid)
            branchPath.addLine(to: branchEnd)
            context.stroke(branchPath, with: .color(.white.opacity(0.35 * Double(growth))), lineWidth: 1)
        }
    }
}
