import SwiftUI

// MARK: - VinylCrateStackArtworkView — "Vinyl Crate Stack"
//
// The cover fronting a small stack of record sleeves peeking out behind it at
// alternating angles, like flipping through a crate — the whole stack gently
// settling and resettling.
struct VinylCrateStackArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    private var c1: Color { palette?.primary ?? AppTheme.dynamicAccent }
    private var c2: Color { palette?.secondary ?? AppTheme.accentSoft }

    private var sleeves: [(color: Color, angle: Double, offsetX: CGFloat)] {
        [(c1.opacity(0.7), -10, -18), (c2.opacity(0.7), 8, 16), (.white.opacity(0.15), -5, -9)]
    }

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let p = ArtworkClock.pingPong(timeline.date, legDuration: 3.0)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.07))

                ForEach(Array(sleeves.enumerated()), id: \.offset) { i, sleeve in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(sleeve.color)
                        .frame(width: 190, height: 190)
                        .rotationEffect(.degrees(sleeve.angle + (-2 + 4 * p)))
                        .offset(x: sleeve.offsetX + (-4 + 8 * p), y: CGFloat(i) * 3)
                        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
                }

                StyleCover(song: song, size: 200, cornerRadius: 10)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 3.8))
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(.easeInOut(duration: 1.0), value: palette)
    }
}
