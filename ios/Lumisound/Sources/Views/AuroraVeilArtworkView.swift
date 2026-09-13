import SwiftUI

// MARK: - AuroraVeilArtworkView — "Aurora Veil"
//
// Luminous curtains of color ripple vertically behind the cover like the
// northern lights, each drifting sideways at its own speed and slowly
// shifting hue.
struct AuroraVeilArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    private let ribbons: [(hueShift: Double, amplitude: CGFloat, frequency: CGFloat, speed: Double, opacity: Double)] = [
        (0.0,  26, 1.1, 7,  0.5),
        (0.12, 20, 1.6, 9,  0.4),
        (0.28, 30, 0.8, 11, 0.35),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.01, green: 0.02, blue: 0.06), Color(red: 0.02, green: 0.05, blue: 0.08)],
                    startPoint: .top, endPoint: .bottom
                )

                ForEach(Array(ribbons.enumerated()), id: \.offset) { _, ribbon in
                    auroraRibbon(t: t, ribbon: ribbon)
                }

                StyleCover(song: song, size: 190, cornerRadius: 20)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                    .shadow(color: .green.opacity(0.35), radius: 26)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 4.0))
    }

    /// One vertical aurora ribbon: a wavy filled band running top-to-bottom,
    /// its horizontal offset undulating with `sin`, colored by a green/mint/
    /// purple gradient that hue-shifts slowly over time.
    private func auroraRibbon(t: Double, ribbon: (hueShift: Double, amplitude: CGFloat, frequency: CGFloat, speed: Double, opacity: Double)) -> some View {
        Canvas { context, size in
            let phase = t / ribbon.speed
            var leftEdge: [CGPoint] = []
            var rightEdge: [CGPoint] = []
            let step: CGFloat = 6
            var y: CGFloat = 0
            while y <= size.height {
                let x = size.width / 2 + sin((y / size.height) * ribbon.frequency * 2 * .pi + phase) * ribbon.amplitude * 3
                leftEdge.append(CGPoint(x: x - 40, y: y))
                rightEdge.append(CGPoint(x: x + 40, y: y))
                y += step
            }

            var path = Path()
            path.addLines(leftEdge)
            path.addLines(rightEdge.reversed())
            path.closeSubpath()

            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [.green, .mint, .purple, .green]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
        .opacity(ribbon.opacity)
        .blendMode(.plusLighter)
        .blur(radius: 6)
        .hueRotation(.degrees(ribbon.hueShift * 360))
        .frame(width: 300, height: 300)
    }
}
