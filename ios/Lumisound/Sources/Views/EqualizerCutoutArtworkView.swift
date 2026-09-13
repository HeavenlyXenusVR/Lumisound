import SwiftUI

// MARK: - EqualizerCutoutArtworkView — "Equalizer Cutout"
//
// The full cover with a row of equalizer bars planted along its bottom edge —
// varied baseline heights for a bar-chart look, all pulsing together in scale
// while playing, colored from the artwork's own palette and lit against a dark
// scrim so they read clearly over any cover.
struct EqualizerCutoutArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private let barCount = 14

    /// Per-bar baseline height ratio, deterministic (seeded) so the layout is
    /// stable across redraws instead of re-randomizing every frame.
    private let barRatios: [CGFloat] = {
        var rng = SeededRandom(seed: 4_242)
        return (0..<14).map { _ in 0.35 + CGFloat(rng.nextDouble()) * 0.65 }
    }()

    private var c1: Color { palette?.primary ?? AppTheme.dynamicAccent }
    private var c2: Color { palette?.secondary ?? AppTheme.accentSoft }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let raw = ArtworkClock.pingPong(timeline.date, legDuration: 0.55)
            let pulseScale = isPlaying ? 0.55 + raw * 0.45 : 0.4

            StyleCover(song: song, size: 300, cornerRadius: 20)
                .clipShape(shape)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 130)
                }
                .overlay(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(Array(barRatios.enumerated()), id: \.offset) { i, ratio in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [i.isMultiple(of: 2) ? c1 : c2, .white.opacity(0.85)],
                                        startPoint: .bottom, endPoint: .top
                                    )
                                )
                                .frame(height: max(6, 90 * ratio * pulseScale))
                        }
                    }
                    .frame(height: 90, alignment: .bottom)
                    .padding(.bottom, 14)
                }
                .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                .shadow(color: c1.opacity(0.35), radius: 22)
                .frame(width: 300, height: 300)
                .animation(.easeOut(duration: 0.4), value: isPlaying)
                .drawingGroup()
        }
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(.easeInOut(duration: 1.0), value: palette)
    }
}
