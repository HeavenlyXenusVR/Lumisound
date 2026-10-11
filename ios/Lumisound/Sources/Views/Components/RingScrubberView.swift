import SwiftUI

struct RingScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var dragAngle: Double? = nil

    private var progress: Double {
        guard duration > 0 else { return 0 }
        if let angle = dragAngle {
            return min(max(angle / (2 * .pi), 0), 1)
        }
        return min(1, position / duration)
    }

    private var displayPosition: TimeInterval {
        dragAngle.map { min(max($0 / (2 * .pi), 0), 1) * duration } ?? position
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                // Track/progress `Circle()` shapes below have no explicit frame, so they
                // inscribe in the full geo box — their stroke centerline sits at exactly
                // half the box's shorter side. The thumb dot's offset must match that
                // radius (not an inset version) or it visibly floats inside the ring
                // instead of riding along the progress arc.
                let radius = min(geo.size.width, geo.size.height) / 2

                ZStack {
                    // Outer decorative dashed ring — rotates while playing.
                    // Both the glow pulse and the rotation are driven from
                    // wall-clock time via `TimelineView`/`ArtworkClock`
                    // rather than `@State` + `repeatForever` — this view
                    // re-renders every 0.25-0.5s while playing (the
                    // `position` parameter ticks that often), and a
                    // `repeatForever` Core Animation transaction doesn't
                    // survive that frequent a re-render without freezing
                    // mid-cycle (same root cause documented in
                    // ArtworkClock's own doc comment, for every Now Playing
                    // artwork style). Simply freezes in place on pause
                    // rather than easing back to a fixed rotation.
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { context in
                        let glowPhase = isPlaying ? ArtworkClock.pingPong(context.date, legDuration: 1.6) : 0
                        let rotation = isPlaying ? ArtworkClock.loop(context.date, cycleDuration: 8) * 360 : 0
                        Circle()
                            .strokeBorder(
                                AppTheme.dynamicAccent.opacity(0.08 + 0.14 * glowPhase),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 7])
                            )
                            .rotationEffect(.degrees(rotation))
                    }

                    // Track ring
                    Circle()
                        .stroke(AppTheme.surface, lineWidth: 10)

                    // Progress arc
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            LinearGradient(
                                colors: [AppTheme.accentSoft, AppTheme.dynamicAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .shadow(
                            color: AppTheme.dynamicAccent.opacity(ringGlow ? 0.55 : 0.15),
                            radius: ringGlow ? 8 : 2
                        )
                        .animation(dragAngle == nil ? .easeInOut(duration: 0.12) : nil, value: progress)

                    // Thumb dot — positioning (offset/rotation) and the glow pulse are
                    // applied on separate nested views. A `repeatForever` animation on
                    // one view applies to ALL of that view's animatable properties, so
                    // putting the pulse on the same view as the rotation caused the
                    // thumb's position to get dragged along by the perpetual pulse
                    // curve instead of the quick progress animation — which is why
                    // the ball visibly lagged behind the actual playback time.
                    // Wall-clock-driven pulse — see the outer ring above for why.
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { context in
                        let phase = isPlaying ? ArtworkClock.pingPong(context.date, legDuration: 1.6) : 0
                        Circle()
                            .fill(AppTheme.dynamicAccent)
                            .frame(width: 16, height: 16)
                            .shadow(
                                color: AppTheme.dynamicAccent.opacity(0.4 + 0.4 * phase),
                                radius: 4 + 6 * phase
                            )
                            .scaleEffect(1.0 + 0.15 * phase)
                    }
                    .offset(y: -radius)
                    // The base offset `(0, -radius)` already sits at the top (12
                    // o'clock), which is where the progress arc's `trim(from:0,
                    // to:_)` starts after its own `-90°` rotation (see the arc
                    // above). So the thumb must sweep from that same zero point —
                    // applying an additional `-90°` here rotated the thumb a
                    // quarter turn ahead of the arc, putting it at 9 o'clock when
                    // progress was ~0 instead of riding the arc's tip at 12.
                    .rotationEffect(.degrees(progress * 360))
                    // Match the progress arc's animation so the thumb glides along
                    // with the fill instead of snapping to each playback tick while
                    // the arc behind it eases smoothly — the mismatch read as the
                    // thumb "jumping" independently of the ring. Disabled while
                    // dragging so the thumb tracks the finger 1:1.
                    .animation(dragAngle == nil ? .easeInOut(duration: 0.12) : nil, value: progress)

                    // Time display
                    VStack(spacing: 2) {
                        Text(formatTime(displayPosition))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(formatTime(duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let dx = val.location.x - center.x
                            let dy = val.location.y - center.y
                            var angle = atan2(dy, dx) + .pi / 2
                            if angle < 0 { angle += 2 * .pi }
                            dragAngle = angle
                        }
                        .onEnded { val in
                            let dx = val.location.x - center.x
                            let dy = val.location.y - center.y
                            var angle = atan2(dy, dx) + .pi / 2
                            if angle < 0 { angle += 2 * .pi }
                            let frac = min(max(angle / (2 * .pi), 0), 1)
                            onSeek(frac * duration)
                            dragAngle = nil
                        }
                )
            }
            .frame(width: 200, height: 200)
            .frame(maxWidth: .infinity)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        t.formattedAsMinutesSeconds
    }
}
