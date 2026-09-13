import SwiftUI

// MARK: - NeonSignFlickerArtworkView — "Neon Sign Flicker"
//
// The cover framed by a glowing neon tube outline that flickers unevenly —
// mostly steady, occasionally dimming or stuttering like a real neon sign —
// against a dim brick-textured backdrop.
struct NeonSignFlickerArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    private var neon: Color { palette?.primary ?? .pink }

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let flicker = flickerIntensity(at: timeline.date)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.03, blue: 0.04))
                    .overlay(brickTexture.opacity(0.5))

                Circle()
                    .fill(neon)
                    .frame(width: 260, height: 260)
                    .blur(radius: 70)
                    .opacity(0.22 * flicker)

                StyleCover(song: song, size: 190, cornerRadius: 18)
                    .clipShape(shape)
                    .overlay(
                        shape.stroke(neon, lineWidth: 3)
                            .shadow(color: neon, radius: 3)
                    )
                    .shadow(color: neon.opacity(0.8 * flicker), radius: 18 + 10 * flicker)
                    .shadow(color: neon.opacity(0.5 * flicker), radius: 34)
                    .opacity(0.55 + 0.45 * flicker)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 3.6))
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(.easeInOut(duration: 1.0), value: palette)
    }

    /// Mostly-lit brightness (~1.0) that occasionally dips into a short,
    /// stuttering flicker — quantizes wall-clock time into fixed steps and
    /// hashes each step through the seeded PRNG so the flicker pattern is
    /// deterministic and repeats on a fixed cycle rather than reseeding
    /// randomly on every redraw.
    private func flickerIntensity(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let stepDuration = 0.09
        let cycleSteps = 100
        let step = Int((t / stepDuration).truncatingRemainder(dividingBy: Double(cycleSteps)))
        var rng = SeededRandom(seed: UInt64(step) &+ 7)
        let roll = rng.nextDouble()
        if roll < 0.08 {
            return 0.25 + roll * 3
        }
        return 1.0
    }

    private var brickTexture: some View {
        Canvas { context, size in
            let rows = 8
            let rowHeight = size.height / CGFloat(rows)
            for row in 0..<rows {
                let offsetX: CGFloat = row.isMultiple(of: 2) ? 0 : -20
                var x = offsetX
                while x < size.width {
                    let rect = CGRect(x: x, y: CGFloat(row) * rowHeight, width: 38, height: rowHeight)
                    context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.white.opacity(0.05)), lineWidth: 1)
                    x += 40
                }
            }
        }
    }
}
