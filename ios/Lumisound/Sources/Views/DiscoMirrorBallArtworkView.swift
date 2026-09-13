import SwiftUI

// MARK: - DiscoMirrorBallArtworkView — "Disco Mirror Ball"
//
// The cover lit by a scatter of small bright reflections that drift in slow
// circles around it, like light bouncing off a spinning mirror ball, over a
// dim spotlight cone.
struct DiscoMirrorBallArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    /// Fixed base position + orbit radius + phase offset per light spot,
    /// deterministic so the scatter is stable across redraws — only the
    /// shared `orbitAngle` animates.
    private let spots: [(baseX: CGFloat, baseY: CGFloat, orbitRadius: CGFloat, phase: Double, flickerDelay: Double)] = [
        (-110, -120, 14, 0,   0.0),
        (100,  -90,  10, 70,  0.15),
        (-90,  100,  12, 140, 0.3),
        (120,  110,  9,  210, 0.45),
        (0,    -140, 11, 280, 0.6),
        (-140, 0,    13, 330, 0.75),
        (140,  10,   10, 50,  0.9),
        (20,   140,  12, 190, 1.05),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let orbitAngle = ArtworkClock.loop(timeline.date, cycleDuration: 9) * 360
            let flicker = 0.35 + 0.6 * ArtworkClock.pingPong(timeline.date, legDuration: 0.9)

            ZStack {
                RadialGradient(
                    colors: [Color(white: 0.14), Color(white: 0.02)],
                    center: .center, startRadius: 20, endRadius: 200
                )

                ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                    let radians = (orbitAngle + spot.phase) * .pi / 180
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .shadow(color: .white, radius: 6)
                        .opacity(flicker)
                        .offset(
                            x: spot.baseX + cos(radians) * spot.orbitRadius,
                            y: spot.baseY + sin(radians) * spot.orbitRadius
                        )
                }

                StyleCover(song: song, size: 220, cornerRadius: 20)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 22, y: 14)
                    .shadow(color: .white.opacity(0.15), radius: 30)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 3.6))
    }
}
