import SwiftUI

/// A soft, animated color wash sampled from the current track's artwork —
/// two large blurred blobs that slowly drift and breathe behind the Now
/// Playing artwork display, similar to Apple Music / Spotify's ambient
/// now-playing backgrounds. Shared across all `NowPlayingArtworkStyle`
/// presets so every style gets a less "flat" backdrop for free.
struct AmbientArtworkBackground: View {
    let song: Song?
    // Same visibility/playing gate every `*ArtworkView` style's own
    // TimelineView takes (see NowPlayingView.isVisibleOnScreen's doc
    // comment) — this wash sits behind ALL of them, so leaving it
    // ungated meant it alone kept the per-frame redraw cost alive even for
    // a style whose own TimelineView WAS correctly paused/off-screen-aware.
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            let drift = ArtworkClock.pingPong(timeline.date, legDuration: 9) * 36
            let pulse = 1.0 + ArtworkClock.pingPong(timeline.date, legDuration: 7) * 0.18

            ZStack {
                if let palette {
                    Circle()
                        .fill(palette.primary)
                        .frame(width: 320, height: 320)
                        .blur(radius: 80)
                        .offset(x: -90 + drift, y: -60 - drift * 0.6)
                        .scaleEffect(pulse)

                    Circle()
                        .fill(palette.secondary)
                        .frame(width: 300, height: 300)
                        .blur(radius: 80)
                        .offset(x: 100 - drift, y: 70 + drift * 0.5)
                        .scaleEffect(2 - pulse)
                }
            }
            .drawingGroup()
            .opacity(0.55)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 1.2), value: palette)
        }
        .task(id: song?.id) {
            await loadPalette()
        }
    }

    private func loadPalette() async {
        palette = await ArtworkPaletteLoader.palette(for: song)
    }
}
