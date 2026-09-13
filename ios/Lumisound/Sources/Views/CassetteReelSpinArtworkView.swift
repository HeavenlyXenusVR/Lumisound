import SwiftUI

// MARK: - CassetteReelSpinArtworkView — "Cassette Reel Spin"
//
// The cover as a cassette's paper label, sitting above twin reel windows
// whose spokes spin continuously while playing, tape visibly wound unevenly
// from one side to the other.
struct CassetteReelSpinArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    private var accent: Color { palette?.primary ?? AppTheme.dynamicAccent }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let spin = ArtworkClock.loop(timeline.date, cycleDuration: 1.6) * 360

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.07, blue: 0.06))

                VStack(spacing: 14) {
                    StyleCover(song: song, size: 170, cornerRadius: 8)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)

                    HStack(spacing: 44) {
                        CassetteReel(fill: 0.68, rotation: spin, accent: accent)
                        CassetteReel(fill: 0.3, rotation: spin, accent: accent)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .drawingGroup()
        }
        .modifier(FloatModifier(isPlaying: isPlaying, amount: 4, speed: 3.6))
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(.easeInOut(duration: 1.0), value: palette)
    }
}

/// A single cassette reel: a dark hub disc with rotating spokes, wound tape
/// shown as a ring whose thickness reflects `fill` (how much tape has wound
/// onto that side).
private struct CassetteReel: View {
    let fill: CGFloat
    let rotation: Double
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(white: 0.12))
                .frame(width: 60, height: 60)

            Circle()
                .stroke(Color(white: 0.35), lineWidth: 6 + fill * 8)
                .frame(width: 46, height: 46)

            ZStack {
                ForEach(0..<6, id: \.self) { i in
                    Capsule()
                        .fill(Color(white: 0.6))
                        .frame(width: 3, height: 14)
                        .offset(y: -10)
                        .rotationEffect(.degrees(Double(i) * 60))
                }
            }
            .rotationEffect(.degrees(rotation))

            Circle()
                .fill(accent.opacity(0.9))
                .frame(width: 10, height: 10)
        }
    }
}
