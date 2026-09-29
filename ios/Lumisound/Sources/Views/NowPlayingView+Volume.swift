import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Volume

    var volumeSection: some View {
        VStack(spacing: 4) {
            // Purely decorative ambient bars (a fake sine wave, not driven by
            // real audio analysis) — deliberately NOT reusing
            // AudioVisualizerService's live FFT tap here, since that tap is
            // shared/idempotent-guarded and already has other consumers (e.g.
            // the "Live Spectrum" artwork style); a second independent
            // start()/stop() caller could cut the tap out from under them.
            AmbientEqualizerBars(isPlaying: player.isPlaying)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                Slider(value: audioBinding(\.volume), in: 0...AudioSettings.maxVolume)
                    .tint(AppTheme.dynamicAccent)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                // AirPlay / output-route picker (AirPlay speakers, Bluetooth, etc.).
                AirPlayRoutePicker(
                    tint: UIColor(AppTheme.textSecondary),
                    activeTint: UIColor(AppTheme.dynamicAccent)
                )
                .frame(width: 30, height: 30)
            }
            // Above 100% the volume slider is boosting gain beyond the
            // device's normal output (via the EQ's global gain stage, in dB —
            // see AudioPlayerManager.applyOutputGain) — a limiter prevents
            // clipping, but it's worth flagging since it's an unusual range
            // for a slider.
            if player.audioSettings.volume > 1.0 {
                let boostDB = 20 * log10(player.audioSettings.volume)
                Text("Boost: +\(String(format: "%.1f", boostDB)) dB")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - AmbientEqualizerBars

/// A small row of animated bars behind the volume slider — purely decorative
/// (a fake sine wave keyed off wall-clock time), not real audio analysis.
/// See `volumeSection`'s comment for why this deliberately avoids
/// `AudioVisualizerService`'s shared FFT tap.
private struct AmbientEqualizerBars: View {
    let isPlaying: Bool
    private let barCount = 16

    var body: some View {
        // Capped at 30fps: decorative bars gain nothing from 120Hz ProMotion
        // redraws, which were costing CPU for the whole time Now Playing is open.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = Double(i) * 0.45
                    let h = isPlaying ? (0.2 + 0.8 * (0.5 + 0.5 * sin(t * 3.2 + phase))) : 0.15
                    Capsule()
                        .fill(AppTheme.dynamicAccent.opacity(0.35))
                        .frame(height: 18 * CGFloat(h))
                }
            }
            .frame(height: 18, alignment: .center)
            .animation(.easeInOut(duration: 0.2), value: isPlaying)
        }
    }
}
