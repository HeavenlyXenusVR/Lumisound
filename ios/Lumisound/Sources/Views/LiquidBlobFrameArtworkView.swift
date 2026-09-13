import SwiftUI

// MARK: - LiquidBlobFrameArtworkView — "Liquid Blob Frame"
//
// Soft, oversized color blobs drift and breathe slowly around the cover like
// a lava lamp seen through frosted glass, gently framing it in color.
struct LiquidBlobFrameArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    private var c1: Color { palette?.primary ?? AppTheme.dynamicAccent }
    private var c2: Color { palette?.secondary ?? AppTheme.accentSoft }

    /// Each blob's base position/size/color, deterministic so the layout is
    /// stable across redraws — only the drift offset animates.
    private var blobs: [(x: CGFloat, y: CGFloat, size: CGFloat, color: Color)] {
        [
            (x: -70, y: -90, size: 150, color: c1),
            (x: 90,  y: -60, size: 120, color: .cyan),
            (x: -90, y: 80,  size: 130, color: c2),
            (x: 80,  y: 100, size: 150, color: .purple),
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let p = ArtworkClock.pingPong(timeline.date, legDuration: 5.5)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.09))

                ForEach(Array(blobs.enumerated()), id: \.offset) { i, blob in
                    Circle()
                        .fill(blob.color)
                        .frame(width: blob.size, height: blob.size)
                        .blur(radius: 46)
                        .opacity(isPlaying ? 0.75 : 0.5)
                        .offset(
                            x: blob.x + (i.isMultiple(of: 2) ? -18 + 36 * p : 18 - 36 * p),
                            y: blob.y + (14 - 28 * p)
                        )
                        .blendMode(.screen)
                }

                StyleCover(song: song, size: 210, cornerRadius: 20)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 22, y: 14)
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
