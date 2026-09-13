import SwiftUI

// MARK: - KaleidoscopeBloomArtworkView — "Kaleidoscope Bloom"
//
// The cover surrounded by six mirrored, rotated echoes of itself arranged in a
// ring — like looking through a kaleidoscope barrel — slowly counter-rotating
// against a soft angular color halo, with the crisp cover fixed at the center.
struct KaleidoscopeBloomArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private var c1: Color { palette?.primary ?? AppTheme.dynamicAccent }
    private var c2: Color { palette?.secondary ?? AppTheme.accentSoft }

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let ringRotation = ArtworkClock.loop(timeline.date, cycleDuration: 26) * 360
            let haloRotation = -ArtworkClock.loop(timeline.date, cycleDuration: 14) * 360
            let bloomOffset = -86 - 22 * ArtworkClock.pingPong(timeline.date, legDuration: 2.2)

            ZStack {
                AngularGradient(
                    colors: [c1, c2, .cyan, .purple, c1],
                    center: .center,
                    angle: .degrees(haloRotation)
                )
                .blur(radius: 40)
                .opacity(isPlaying ? 0.5 : 0.3)
                .frame(width: 300, height: 300)
                .clipShape(Circle())

                // Six mirrored echoes ringed around the center, each a faint,
                // rotated/reflected copy of the cover — the "kaleidoscope" repeat.
                ZStack {
                    ForEach(0..<6, id: \.self) { i in
                        StyleCover(song: song, size: 128, cornerRadius: 16)
                            .clipShape(shape)
                            .scaleEffect(x: i.isMultiple(of: 2) ? 1 : -1, y: 1)
                            .opacity(0.35)
                            .saturation(1.3)
                            .offset(y: bloomOffset)
                            .rotationEffect(.degrees(Double(i) * 60))
                            .blendMode(.plusLighter)
                    }
                }
                .rotationEffect(.degrees(ringRotation))
                .frame(width: 300, height: 300)

                StyleCover(song: song, size: 190, cornerRadius: 20)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                    .shadow(color: c1.opacity(0.5), radius: 26)
            }
            .frame(width: 300, height: 300)
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 3.4))
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(.easeInOut(duration: 1.0), value: palette)
    }
}
