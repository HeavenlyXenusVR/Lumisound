import SwiftUI

// MARK: - CometOrbitArtworkView — "Comet Orbit"
//
// A bright comet, trailing a fading dust tail, circles the cover forever like
// a tiny moon on a fixed orbit.
struct CometOrbitArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private let orbitRadiusX: CGFloat = 150
    private let orbitRadiusY: CGFloat = 80
    /// Trailing dots behind the comet head, each a fixed angular step back
    /// with decreasing size/opacity — a simple discrete tail.
    private let tailSteps = 7

    private var cometColor: Color { palette?.secondary ?? .cyan }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let orbitAngle = ArtworkClock.loop(timeline.date, cycleDuration: 6) * 360

            ZStack {
                ForEach(0..<tailSteps, id: \.self) { i in
                    let t = Double(i) / Double(tailSteps)
                    let angle = (orbitAngle - Double(i) * 6) * .pi / 180
                    Circle()
                        .fill(cometColor)
                        .frame(width: 9 - CGFloat(i) * 1.0, height: 9 - CGFloat(i) * 1.0)
                        .opacity((1 - t) * 0.8)
                        .blur(radius: CGFloat(i) * 0.4)
                        .offset(x: cos(angle) * orbitRadiusX, y: sin(angle) * orbitRadiusY)
                }

                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: cometColor, radius: 10)
                    .offset(
                        x: cos(orbitAngle * .pi / 180) * orbitRadiusX,
                        y: sin(orbitAngle * .pi / 180) * orbitRadiusY
                    )

                StyleCover(song: song, size: 190, cornerRadius: 20)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                    .shadow(color: cometColor.opacity(0.4), radius: 22)
            }
            .frame(width: 300, height: 300)
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 5, speed: 3.6))
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(.easeInOut(duration: 1.0), value: palette)
    }
}
