import SwiftUI

/// A large filling capsule with the elapsed/remaining time printed directly on
/// top of it — the fill clips to reveal a light-on-dark label as progress advances.
struct PillScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double? = nil

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, dragFraction ?? (position / duration))
    }

    private var displayPosition: TimeInterval {
        dragFraction.map { $0 * duration } ?? position
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(AppTheme.surface)

                // Fill. The glow pulse is driven from wall-clock time via
                // `TimelineView`/`ArtworkClock` rather than a `@State` flag
                // animated with `repeatForever` — this view re-renders every
                // 0.25-0.5s while playing (the `position` parameter ticks
                // that often), and a `repeatForever` Core Animation
                // transaction doesn't survive that frequent a re-render
                // without freezing mid-cycle (same root cause documented in
                // ArtworkClock's own doc comment, for every Now Playing
                // artwork style).
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { context in
                    let phase = isPlaying ? ArtworkClock.pingPong(context.date, legDuration: 1.6) : 0
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.dynamicAccent, AppTheme.accentSoft],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geo.size.height, geo.size.width * CGFloat(progress)))
                        .shadow(color: AppTheme.dynamicAccent.opacity(0.2 + 0.3 * phase), radius: 4 + 6 * phase)
                }
                .animation(.easeOut(duration: 0.15), value: progress)

                // Labels — same two Text views drawn twice (once light, once dark)
                // and clipped against the fill so each half reads against its
                // own background, like a "liquid" progress label.
                timeLabels
                    .foregroundStyle(AppTheme.textPrimary)

                timeLabels
                    .foregroundStyle(Color.black.opacity(0.75))
                    .mask(
                        Capsule()
                            .frame(width: max(geo.size.height, geo.size.width * CGFloat(progress)))
                            .animation(.easeOut(duration: 0.15), value: progress)
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        dragFraction = min(max(val.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { val in
                        let frac = min(max(val.location.x / geo.size.width, 0), 1)
                        onSeek(frac * duration)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 44)
    }

    private var timeLabels: some View {
        HStack {
            Text(formatTime(displayPosition))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
            Spacer()
            Text("-" + formatTime(max(0, duration - displayPosition)))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        t.formattedAsMinutesSeconds
    }
}
