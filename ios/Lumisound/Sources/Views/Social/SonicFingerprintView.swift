import SwiftUI

// MARK: - SonicFingerprintView
//
// Shows what a library actually sounds like: its median tempo, how varied that
// is, and its tonal balance across the ten EQ bands.
//
// This is derived entirely from measurements the server already makes for Auto
// EQ and Smart Crossfade, so it costs nothing extra to produce — and unlike
// every other thing on a profile, it cannot be curated. A pinned track or a
// featured playlist says what someone wants to be seen listening to; this says
// what they actually listen to.
struct SonicFingerprintView: View {
    let fingerprint: SonicFingerprint

    var body: some View {
        if fingerprint.available {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let spectrum = fingerprint.spectrum, let bands = fingerprint.bandHz,
                   spectrum.count == bands.count {
                    curve(spectrum: spectrum, bands: bands)
                }
                if let count = fingerprint.trackCount {
                    Text("from \(count) analysed track\(count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Listening Fingerprint", systemImage: "waveform.badge.magnifyingglass")
                .font(.subheadline.weight(.semibold))
            if let summary = fingerprint.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The tonal balance as a bar per band.
    ///
    /// Drawn relative to the curve's OWN range rather than an absolute dB scale.
    /// Every real track falls away steeply toward the top — that is simply how
    /// music and lossy encoding both behave — so on an absolute scale every
    /// fingerprint looks like the same downward ramp and the differences that
    /// actually distinguish two libraries are invisible.
    private func curve(spectrum: [Double], bands: [Int]) -> some View {
        let lowest = spectrum.min() ?? 0
        let highest = spectrum.max() ?? 1
        let span = max(1, highest - lowest)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(spectrum.enumerated()), id: \.offset) { index, value in
                    let normalised = (value - lowest) / span
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor, .accentColor.opacity(0.45)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        // A floor so a band at the very bottom is still drawn —
                        // an invisible bar reads as missing data rather than as
                        // "there is little here".
                        .frame(height: max(3, 46 * normalised))
                        .accessibilityLabel("\(bands[index]) hertz")
                        .accessibilityValue(String(format: "%.1f decibels", value))
                }
            }
            .frame(height: 46)

            HStack {
                Text("bass")
                Spacer()
                Text("mids")
                Spacer()
                Text("treble")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - MusicMatchReasons

/// The plain-language reasons behind a Music Match score.
///
/// The score used to be a bare percentage, which is not something anyone can
/// agree or disagree with. "You both lean fast" and "quite different tonal
/// balance" are claims a listener can check against their own experience — and
/// they also make it visible when a match came from the two libraries sounding
/// alike rather than from sharing any artist, which is the case the old
/// name-overlap score could not represent at all.
struct MusicMatchReasons: View {
    let compatibility: MusicCompatibility

    var body: some View {
        if !compatibility.reasons.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(compatibility.reasons, id: \.self) { reason in
                    Label {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "sparkle")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                if let sonic = compatibility.sonicScore,
                   compatibility.sharedArtists.isEmpty {
                    // Worth stating outright: with no artists in common the
                    // entire score rests on the two libraries sounding alike,
                    // and that is weaker evidence than a shared artist.
                    Text("Based on how your libraries sound — \(sonic)% alike — rather than shared artists.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
