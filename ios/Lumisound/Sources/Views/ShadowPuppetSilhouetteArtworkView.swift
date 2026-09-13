import SwiftUI

// MARK: - ShadowPuppetSilhouetteArtworkView — "Shadow Puppet Silhouette"
//
// The cover darkened to a silhouette against a warm backlight glow, swaying
// gently from a fixed pivot overhead like a shadow puppet on a rod.
struct ShadowPuppetSilhouetteArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let sway = -4 + 8 * ArtworkClock.pingPong(timeline.date, legDuration: 2.8)

            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.55, green: 0.32, blue: 0.08), Color(red: 0.05, green: 0.02, blue: 0.0)],
                    center: UnitPoint(x: 0.5, y: 0.15), startRadius: 10, endRadius: 230
                )

                // The "rod" the puppet sways from.
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .frame(width: 3, height: 40)
                    .offset(y: -160)

                StyleCover(song: song, size: 200, cornerRadius: 20)
                    .colorMultiply(.black)
                    .brightness(-0.05)
                    .clipShape(shape)
                    .overlay(shape.fill(.black.opacity(0.35)))
                    .overlay(shape.stroke(.black.opacity(0.6), lineWidth: 2))
                    .offset(y: -30)
                    .rotationEffect(.degrees(sway), anchor: UnitPoint(x: 0.5, y: -0.15))
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .drawingGroup()
        }
    }
}
