import SwiftUI

// MARK: - OrigamiFoldRevealArtworkView — "Origami Fold"
//
// The cover sliced into three horizontal paper panels, each hinged at an
// alternating edge and gently rocking in 3D like a folded map breathing open
// and shut — a continuous, subtle motion rather than a one-shot reveal, so it
// stays alive for as long as the track plays.
struct OrigamiFoldRevealArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let size: CGFloat = 240
    private let stripCount = 3
    private var stripHeight: CGFloat { size / CGFloat(stripCount) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let fold = -7 + 14 * ArtworkClock.pingPong(timeline.date, legDuration: 2.4)

            VStack(spacing: 0) {
                strip(0, anchor: .bottom, sign: 1, foldDegrees: fold)
                strip(1, anchor: .top, sign: -1, foldDegrees: fold)
                strip(2, anchor: .top, sign: 1, foldDegrees: fold)
            }
            .frame(width: size, height: size)
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

    /// One horizontal slice of the full cover, shown via a top-aligned crop of
    /// an oversized copy of `StyleCover` offset upward by `index * stripHeight`
    /// — an explicit, unambiguous "sprite sheet slice" (alignment: .top means
    /// the crop window always starts from the offset content's top edge, so
    /// the math doesn't depend on any implicit centering behavior).
    private func strip(_ index: Int, anchor: UnitPoint, sign: CGFloat, foldDegrees: Double) -> some View {
        StyleCover(song: song, size: size, cornerRadius: 0)
            .offset(y: -CGFloat(index) * stripHeight)
            .frame(width: size, height: stripHeight, alignment: .top)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.18), .clear, .black.opacity(0.18)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .rotation3DEffect(
                .degrees(foldDegrees * sign),
                axis: (x: 1, y: 0, z: 0),
                anchor: anchor,
                perspective: 0.5
            )
            .zIndex(Double(stripCount - index))
    }
}
