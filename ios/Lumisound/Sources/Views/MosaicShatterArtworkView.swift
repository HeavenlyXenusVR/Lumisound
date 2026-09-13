import SwiftUI

// MARK: - MosaicShatterArtworkView — "Mosaic Shatter"
//
// The cover diced into a 4×4 grid of tiles that breathe gently apart and back
// together — each tile drifting along its own fixed direction away from
// center, like a mosaic that's just slightly come loose.
struct MosaicShatterArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let gridSize: CGFloat = 240
    private let columns = 4
    private var tileSize: CGFloat { gridSize / CGFloat(columns) }

    /// Per-tile fixed rotation + drift direction, deterministic (seeded) so
    /// the shatter pattern is stable across redraws — only `shatter` (the
    /// shared 0...1 progress) animates. Computed once (not a computed
    /// property) since `body` re-evaluates every animation frame.
    private let tiles: [(row: Int, col: Int, angle: Double, dx: CGFloat, dy: CGFloat)] = {
        var rng = SeededRandom(seed: 9_001)
        var result: [(row: Int, col: Int, angle: Double, dx: CGFloat, dy: CGFloat)] = []
        for row in 0..<4 {
            for col in 0..<4 {
                let angle = (rng.nextDouble() - 0.5) * 10
                let dx = CGFloat(col) - 1.5
                let dy = CGFloat(row) - 1.5
                result.append((row: row, col: col, angle: angle, dx: dx, dy: dy))
            }
        }
        return result
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let shatter = ArtworkClock.pingPong(timeline.date, legDuration: 2.6)

            ZStack {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    StyleCover(song: song, size: gridSize, cornerRadius: 0)
                        .offset(x: -CGFloat(tile.col) * tileSize, y: -CGFloat(tile.row) * tileSize)
                        .frame(width: tileSize, height: tileSize, alignment: .topLeading)
                        .clipped()
                        .overlay(Rectangle().stroke(.black.opacity(0.25), lineWidth: 0.5))
                        .rotationEffect(.degrees(tile.angle * shatter))
                        .offset(x: tile.dx * shatter * 5, y: tile.dy * shatter * 5)
                        .position(
                            x: (CGFloat(tile.col) + 0.5) * tileSize,
                            y: (CGFloat(tile.row) + 0.5) * tileSize
                        )
                }
            }
            .frame(width: gridSize, height: gridSize)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 22, y: 14)
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 3.4))
    }
}
