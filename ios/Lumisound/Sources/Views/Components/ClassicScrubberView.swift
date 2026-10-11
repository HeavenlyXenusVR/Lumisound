import SwiftUI

struct ClassicScrubberView: View {
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
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.surface)
                        .frame(height: 4)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.accentSoft, AppTheme.dynamicAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(progress), height: 4)
                        .animation(.easeOut(duration: 0.15), value: progress)

                    // Glowing thumb — positioning (offset) and the pulse are applied
                    // on separate nested views. A `repeatForever` animation on one
                    // view applies to ALL of that view's animatable properties, so
                    // putting the pulse on the same view as the offset caused the
                    // thumb's position to get dragged along by the perpetual pulse
                    // curve instead of tracking playback progress directly.
                    //
                    // The pulse itself is driven from wall-clock time via
                    // `TimelineView`/`ArtworkClock` rather than a `@State` flag
                    // animated with `repeatForever` — this view re-renders every
                    // 0.25-0.5s while playing (the `position` parameter ticks
                    // that often), and a `repeatForever` Core Animation transaction
                    // doesn't survive that frequent a re-render without freezing
                    // mid-cycle (same root cause documented in ArtworkClock's own
                    // doc comment, for every Now Playing artwork style).
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { context in
                        let phase = isPlaying ? ArtworkClock.pingPong(context.date, legDuration: 1.4) : 0
                        Circle()
                            .fill(AppTheme.dynamicAccent)
                            .frame(width: 16, height: 16)
                            .shadow(
                                color: AppTheme.dynamicAccent.opacity(0.4 + 0.45 * phase),
                                radius: 5 + 7 * phase
                            )
                            .scaleEffect(1.0 + 0.18 * phase)
                    }
                    .offset(x: max(0, geo.size.width * CGFloat(progress) - 8))
                    .animation(.easeOut(duration: 0.15), value: progress)
                }
                .frame(height: 16)
                .contentShape(Rectangle().inset(by: -16))
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
            .frame(height: 40)

            HStack {
                Text(formatTime(displayPosition))
                    .monospacedDigit()
                Spacer()
                Text("-" + formatTime(max(0, duration - displayPosition)))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        t.formattedAsMinutesSeconds
    }
}
