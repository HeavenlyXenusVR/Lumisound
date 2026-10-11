import SwiftUI

/// A thin multi-color neon tube with a bright comet-like playhead — the
/// filled portion is a cyan-to-magenta gradient (rather than the app accent
/// color used elsewhere) and the playhead trails a soft fading glow behind
/// it, giving this preset a distinct "glowing tube" identity.
struct NeonLineScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double? = nil

    private let neonGradient = LinearGradient(
        colors: [
            Color(red: 0.25, green: 0.95, blue: 1.0),
            AppTheme.dynamicAccent,
            Color(red: 1.0, green: 0.35, blue: 0.95)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, dragFraction ?? (position / duration))
    }

    private var displayPosition: TimeInterval {
        dragFraction.map { $0 * duration } ?? position
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                // The glow pulse (used by all four pieces below) is driven
                // from wall-clock time via `TimelineView`/`ArtworkClock`
                // rather than a `@State` flag animated with `repeatForever`
                // — this view re-renders every 0.25-0.5s while playing (the
                // `position` parameter ticks that often), and a
                // `repeatForever` Core Animation transaction doesn't
                // survive that frequent a re-render without freezing
                // mid-cycle (same root cause documented in ArtworkClock's
                // own doc comment, for every Now Playing artwork style).
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { context in
                    let phase = isPlaying ? ArtworkClock.pingPong(context.date, legDuration: 1.2) : 0
                    ZStack(alignment: .leading) {
                        // Unlit tube
                        Capsule()
                            .fill(AppTheme.surface)
                            .frame(height: 4)
                            .frame(maxHeight: .infinity, alignment: .center)

                        // Lit neon tube
                        Capsule()
                            .fill(neonGradient)
                            .frame(width: geo.size.width * CGFloat(progress), height: 4)
                            .shadow(color: Color(red: 0.25, green: 0.95, blue: 1.0).opacity(0.35 + 0.45 * phase), radius: 4 + 6 * phase)
                            .shadow(color: Color(red: 1.0, green: 0.35, blue: 0.95).opacity(0.35 + 0.45 * phase), radius: 4 + 6 * phase)
                            .frame(maxHeight: .infinity, alignment: .center)

                        // Comet trail — fading streak behind the playhead
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.25 + 0.3 * phase)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: min(geo.size.width * CGFloat(progress), 46), height: 4)
                            .offset(x: max(0, geo.size.width * CGFloat(progress) - min(geo.size.width * CGFloat(progress), 46)))
                            .frame(maxHeight: .infinity, alignment: .center)
                            .blendMode(.plusLighter)

                        // Playhead spark
                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: Color(red: 0.25, green: 0.95, blue: 1.0).opacity(0.6 + 0.4 * phase), radius: 7 + 7 * phase)
                            .shadow(color: Color(red: 1.0, green: 0.35, blue: 0.95).opacity(0.4 + 0.4 * phase), radius: 5 + 5 * phase)
                            .offset(x: geo.size.width * CGFloat(progress) - 7)
                            .frame(maxHeight: .infinity, alignment: .center)
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
            }
            .frame(height: 24)
            .animation(.easeOut(duration: 0.15), value: progress)

            HStack {
                Text(formatTime(displayPosition))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text("-" + formatTime(max(0, duration - displayPosition)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        t.formattedAsMinutesSeconds
    }
}
