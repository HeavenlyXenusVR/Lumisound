import SwiftUI

// MARK: - VinylGrooveSpiralArtworkView — "Vinyl Groove Spiral"
//
// The cover as the label at the center of a spinning vinyl record, fine
// concentric grooves etched across the black disc and a tonearm resting near
// its edge — spins continuously while playing, and lifts clear when paused.
struct VinylGrooveSpiralArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager

    private let discSize: CGFloat = 260
    private let labelSize: CGFloat = 104

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let spin = ArtworkClock.loop(timeline.date, cycleDuration: 4.2) * 360

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.04, green: 0.04, blue: 0.05))

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(white: 0.16), Color(white: 0.04), Color(white: 0.1)],
                                center: .center, startRadius: 0, endRadius: discSize / 2
                            )
                        )
                        .frame(width: discSize, height: discSize)

                    grooves
                        .frame(width: discSize, height: discSize)

                    StyleCover(song: song, size: labelSize, cornerRadius: labelSize / 2)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))

                    Circle()
                        .fill(Color(white: 0.02))
                        .frame(width: 8, height: 8)
                }
                .frame(width: discSize, height: discSize)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
                .rotationEffect(.degrees(spin))

                tonearm
                    .rotationEffect(.degrees(isPlaying ? -16 : -30))
                    .offset(x: 86, y: -104)
                    .animation(.easeInOut(duration: 0.6), value: isPlaying)
            }
            .frame(width: 300, height: 300)
            .drawingGroup()
        }
    }

    /// Fine concentric groove rings drawn out from the label to the disc's
    /// edge (the disc itself spins via the outer `.rotationEffect`, so these
    /// don't need their own animation).
    private var grooves: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var radius: CGFloat = labelSize / 2 + 10
            while radius < discSize / 2 - 4 {
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.06)), lineWidth: 1)
                radius += 4
            }
        }
    }

    /// A simplified tonearm silhouette: a straight arm running down to a
    /// headshell/needle resting near the disc's edge.
    private var tonearm: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Color(white: 0.7))
                .frame(width: 6, height: 120)
            Circle()
                .fill(Color(white: 0.85))
                .frame(width: 14, height: 14)
                .offset(y: 6)
        }
        .frame(width: 40, height: 130)
    }
}
