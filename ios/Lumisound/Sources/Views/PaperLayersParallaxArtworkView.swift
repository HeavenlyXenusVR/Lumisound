import SwiftUI

// MARK: - PaperLayersParallaxArtworkView — "Paper Layers Parallax"
//
// Cutout paper shapes stacked behind the cover at different depths, each
// drifting at its own slow rate for a sense of parallax depth, like a
// layered construction-paper collage.
struct PaperLayersParallaxArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private var c1: Color { palette?.primary ?? AppTheme.dynamicAccent }
    private var c2: Color { palette?.secondary ?? AppTheme.accentSoft }

    /// Each background layer: size, color, base rotation, drift amount/speed
    /// (larger = further back = slower + smaller drift, for the parallax cue).
    private var layers: [(size: CGFloat, color: Color, rotation: Double, driftAmount: CGFloat, speed: Double)] {
        [
            (280, c1.opacity(0.55), -8, 6, 6.5),
            (250, c2.opacity(0.6), 6, 10, 5.0),
            (225, .white.opacity(0.12), -4, 14, 3.8),
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.06, green: 0.06, blue: 0.08))

                ForEach(Array(layers.enumerated()), id: \.offset) { i, layer in
                    // Each layer has its own independent period (`layer.speed`
                    // as the one-way leg duration) — larger/further-back layers
                    // drift slower, for the parallax cue.
                    let p = ArtworkClock.pingPong(timeline.date, legDuration: layer.speed)
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(layer.color)
                        .frame(width: layer.size, height: layer.size)
                        .rotationEffect(.degrees(layer.rotation + (-3 + 6 * p)))
                        .offset(
                            x: layer.driftAmount * (-1 + 2 * p),
                            y: layer.driftAmount * 0.6 * (1 - 2 * p)
                        )
                        .id(i)
                }

                StyleCover(song: song, size: 200, cornerRadius: 18)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 3.6))
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(.easeInOut(duration: 1.0), value: palette)
    }
}
