import SwiftUI

// MARK: - BioluminescentTideArtworkView — "Bioluminescent Tide"
//
// Glowing teal waves roll across the lower half like a bioluminescent tide,
// with the cover floating serenely above them like a pearl or a rising moon.
struct BioluminescentTideArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let phase = ArtworkClock.loop(timeline.date, cycleDuration: 6) * 2 * .pi

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.05, blue: 0.12), Color(red: 0.03, green: 0.12, blue: 0.16)],
                    startPoint: .top, endPoint: .bottom
                )

                wave(amplitude: 14, frequency: 1.4, baseline: 0.68, phaseOffset: 0, phase: phase, color: .cyan, opacity: 0.35)
                wave(amplitude: 10, frequency: 1.9, baseline: 0.78, phaseOffset: 2.1, phase: phase, color: .teal, opacity: 0.4)
                wave(amplitude: 8, frequency: 2.4, baseline: 0.88, phaseOffset: 4.3, phase: phase, color: .mint, opacity: 0.45)

                StyleCover(song: song, size: 190, cornerRadius: 20)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                    .shadow(color: .cyan.opacity(0.45), radius: 26)
                    .offset(y: -30)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 6, speed: 4.2))
    }

    /// One glowing sine-wave band, drawn as a filled shape from the wave line
    /// down to the bottom edge, scrolling horizontally via `phase`.
    private func wave(amplitude: CGFloat, frequency: CGFloat, baseline: CGFloat, phaseOffset: CGFloat, phase: CGFloat, color: Color, opacity: Double) -> some View {
        Canvas { context, size in
            let baseY = size.height * baseline
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: baseY))
            let step: CGFloat = 4
            var x: CGFloat = 0
            while x <= size.width {
                let y = baseY + sin((x / size.width) * frequency * 2 * .pi + phase + phaseOffset) * amplitude
                path.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(color.opacity(opacity)))
        }
        .frame(width: 300, height: 300)
    }
}
