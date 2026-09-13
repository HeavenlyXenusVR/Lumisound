import SwiftUI

// MARK: - VHSScanGlitchArtworkView — "VHS Scan Glitch"
//
// The cover rendered like a paused VHS frame: rolling scanlines drift down
// the picture, faint grain sits over the whole thing, and the color channels
// momentarily split apart in a brief glitch stutter.
struct VHSScanGlitchArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    private let coverSize: CGFloat = 210

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let glitch = glitchOffset(at: timeline.date)
            let scanlineScroll = ArtworkClock.loop(timeline.date, cycleDuration: 4) * coverSize

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black)

                ZStack {
                    StyleCover(song: song, size: coverSize, cornerRadius: 0)
                        .colorMultiply(.cyan)
                        .blendMode(.screen)
                        .offset(x: -glitch, y: 0)
                        .opacity(glitch > 0 ? 0.7 : 0)

                    StyleCover(song: song, size: coverSize, cornerRadius: 0)
                        .colorMultiply(.red)
                        .blendMode(.screen)
                        .offset(x: glitch, y: 0)
                        .opacity(glitch > 0 ? 0.7 : 0)

                    StyleCover(song: song, size: coverSize, cornerRadius: 0)

                    scanlines
                        .frame(width: coverSize, height: coverSize)
                        .offset(y: scanlineScroll.truncatingRemainder(dividingBy: 8))

                    FilmGrainOverlay()
                        .opacity(0.35)
                }
                .frame(width: coverSize, height: coverSize)
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 3.8))
    }

    /// A brief RGB-split "glitch" pulse, quantized into fixed steps and
    /// hashed through the seeded PRNG so the pattern is deterministic and
    /// repeats on a fixed cycle rather than reseeding on every redraw.
    private func glitchOffset(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let stepDuration = 0.12
        let cycleSteps = 60
        let step = Int((t / stepDuration).truncatingRemainder(dividingBy: Double(cycleSteps)))
        var rng = SeededRandom(seed: UInt64(step) &+ 41)
        let roll = rng.nextDouble()
        return roll < 0.1 ? CGFloat(2 + roll * 30) : 0
    }

    /// Faint horizontal scanlines tiled across the frame.
    private var scanlines: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height + 8 {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.black.opacity(0.22))
                )
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}
