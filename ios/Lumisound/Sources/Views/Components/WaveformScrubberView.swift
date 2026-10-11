import SwiftUI
import DSWaveformImage
import DSWaveformImageViews

// MARK: - WaveformScrubberView
//
// Renders the actual audio waveform of a local file using DSWaveformImage.
// Two waveform layers are stacked:
//   1. A dim background layer (full duration)
//   2. A tinted foreground layer clipped to the current playback progress
// Tap or drag anywhere on the waveform to seek.

struct WaveformScrubberView: View {
    let url: URL
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
                    // Dim background — shows the full track waveform
                    WaveformView(
                        audioURL: url,
                        configuration: Waveform.Configuration(
                            style: .striped(.init(
                                color: UIColor(AppTheme.textSecondary).withAlphaComponent(0.28),
                                width: 2,
                                spacing: 1
                            )),
                            verticalScalingFactor: 0.85
                        )
                    )

                    // Tinted foreground — clipped to playhead position
                    WaveformView(
                        audioURL: url,
                        configuration: Waveform.Configuration(
                            style: .striped(.init(
                                color: UIColor(AppTheme.dynamicAccent),
                                width: 2,
                                spacing: 1
                            )),
                            verticalScalingFactor: 0.85
                        )
                    )
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: max(2, geo.size.width * progress))
                            .frame(maxHeight: .infinity)
                    }

                    // Animated playhead line — positioning (offset) and the pulse
                    // are applied on separate nested views; a `repeatForever`
                    // animation on one view applies to ALL of that view's
                    // animatable properties, so putting the pulse on the same
                    // view as the offset caused the playhead to lag behind the
                    // actual playback position, dragged along by the pulse curve.
                    //
                    // The pulse itself is driven from wall-clock time via
                    // `TimelineView`/`ArtworkClock` rather than a `@State` flag
                    // animated with `repeatForever` — this view re-renders every
                    // 0.25-0.5s while playing (the `position` parameter ticks
                    // that often), and a `repeatForever` Core Animation
                    // transaction doesn't survive that frequent a re-render
                    // without freezing mid-cycle (same root cause documented in
                    // ArtworkClock's own doc comment, for every Now Playing
                    // artwork style). `paused: !isPlaying` stops the timer
                    // entirely rather than just visually stopping it, when the
                    // pulse isn't needed.
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { context in
                        let phase = isPlaying ? ArtworkClock.pingPong(context.date, legDuration: 1.1) : 0
                        ZStack {
                            // Glow halo behind the line
                            Rectangle()
                                .fill(AppTheme.dynamicAccent.opacity(0.35 * phase))
                                .frame(width: 8)
                                .blur(radius: 4)
                            // Main line
                            Rectangle()
                                .fill(Color.white.opacity(0.75 + 0.25 * phase))
                                .frame(width: 2)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .offset(x: max(0, geo.size.width * progress - 1))
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
            .frame(height: 52)

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
