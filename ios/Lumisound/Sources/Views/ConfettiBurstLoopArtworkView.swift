import SwiftUI

// MARK: - ConfettiBurstLoopArtworkView — "Confetti Burst Loop"
//
// Colorful confetti pieces continuously burst outward from behind the cover
// and fade before looping back to start again.
struct ConfettiBurstLoopArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private let confettiColors: [Color] = [.pink, .yellow, .cyan, .purple, .green, .orange]

    /// Each confetti piece: launch angle, max travel distance, size, spin
    /// speed, color index, and a phase offset so pieces don't all burst in
    /// lockstep — all fixed/deterministic, only the shared `burst` (0...1,
    /// looping) drives position/opacity.
    private let pieces: [(angle: Double, distance: CGFloat, size: CGFloat, spin: Double, colorIndex: Int, phase: CGFloat)] = {
        var rng = SeededRandom(seed: 5_150)
        return (0..<18).map { i in
            let angle = rng.nextDouble() * 360
            let distance = 90 + CGFloat(rng.nextDouble()) * 70
            let size = 5 + CGFloat(rng.nextDouble()) * 5
            let spin = 180 + rng.nextDouble() * 360
            let phase = CGFloat(i) / 18.0
            return (angle: angle, distance: distance, size: size, spin: spin, colorIndex: i % 6, phase: phase)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let burst = ArtworkClock.loop(timeline.date, cycleDuration: 3.0)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.05, blue: 0.1))

                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    // Each piece's own progress loops 0...1 continuously, offset
                    // by its phase, so the bursts are staggered rather than synced.
                    let t = (burst + piece.phase).truncatingRemainder(dividingBy: 1)
                    let radians = piece.angle * .pi / 180
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(confettiColors[piece.colorIndex])
                        .frame(width: piece.size, height: piece.size * 0.5)
                        .rotationEffect(.degrees(piece.spin * Double(t)))
                        .opacity(Double(1 - t))
                        .offset(x: cos(radians) * piece.distance * t, y: sin(radians) * piece.distance * t)
                }

                StyleCover(song: song, size: 190, cornerRadius: 20)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 3.6))
    }
}
