import SwiftUI

// MARK: - ChalkboardSketchArtworkView — "Chalkboard Sketch"
//
// The cover desaturated like a photo pinned to a chalkboard, framed by a
// hand-drawn chalk border that continuously traces itself around the edge.
struct ChalkboardSketchArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let trimEnd = ArtworkClock.pingPong(timeline.date, legDuration: 3.4)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.13, blue: 0.1))
                    .overlay(FilmGrainOverlay().opacity(0.5))

                StyleCover(song: song, size: 210, cornerRadius: 14)
                    .saturation(0.35)
                    .contrast(1.05)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.5), lineWidth: 3))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 8)

                shape
                    .trim(from: 0, to: trimEnd)
                    .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 3]))
                    .frame(width: 224, height: 224)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 3.8))
    }
}
