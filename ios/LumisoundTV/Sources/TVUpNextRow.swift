import SwiftUI

// MARK: - TVUpNextRow
//
// One entry in the Up Next queue.
//
// Three states, because a queue is a timeline and not just a list: tracks
// already played, the one playing, and the ones still to come. The old panel
// drew all three identically apart from a grey speaker glyph on the current row,
// so the queue gave no sense of position at all — you could not see at a glance
// how far through it you were.
//
//   - played    — dimmed, and numbered rather than illustrated. It is history.
//   - current   — accent-lit, with an animated bar meter while audio is running,
//                 so the row agrees with what you can hear.
//   - upcoming  — full brightness with artwork, the normal case.
struct TVUpNextRow: View {
    let item: TVPlayable
    let position: Int
    let isCurrent: Bool
    let isPlayed: Bool
    let isPlaying: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 20) {
            leading

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 24, weight: isCurrent ? .bold : .semibold))
                    .foregroundStyle(isCurrent ? Color.white : .white.opacity(isPlayed ? 0.5 : 0.92))
                    .lineLimit(1)
                Text(item.artist.isEmpty ? "Unknown Artist" : item.artist)
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(isPlayed ? 0.3 : 0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isCurrent {
                Text(isPlaying ? "PLAYING" : "PAUSED")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(TVPalette.neon)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .opacity(isPlayed && !isFocused ? 0.65 : 1)
        .tvNeonCard(
            isFocused: isFocused,
            // The playing row keeps a lit rim even unfocused, so it stays
            // findable after focus has moved on down the queue.
            tint: isCurrent ? TVPalette.neon : nil
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule()
                    .fill(LinearGradient(colors: [TVPalette.neon, TVPalette.neonAlt],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 4, height: 34)
                    .offset(x: -2)
                    .shadow(color: TVPalette.neon, radius: 8)
            }
        }
    }

    /// Artwork for anything still ahead, a position number for what's behind.
    /// Loading covers for tracks already played spends bandwidth and memory on
    /// the part of the queue nobody is looking at.
    @ViewBuilder
    private var leading: some View {
        if isPlayed {
            Text("\(position)")
                .font(TVType.meta)
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 62, height: 62)
        } else {
            TVAuthImage(url: item.artworkURL, token: item.authToken) {
                TVArtPlaceholder(systemImage: "music.note", iconScale: 0.42)
            }
            .frame(width: 62, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .overlay {
                if isCurrent {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.black.opacity(0.45))
                        TVPlayingMeter(isAnimating: isPlaying)
                    }
                }
            }
        }
    }
}

/// Three bars that rise and fall while audio is running — the standard "this is
/// the one playing" cue, and readable from a sofa in a way a small speaker glyph
/// is not. Frozen at rest when paused rather than hidden, so the row still reads
/// as the current one.
struct TVPlayingMeter: View {
    let isAnimating: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        // One shared phase, sampled at three offsets, rather than three
        // independent animations — the bars stay in a fixed relationship to each
        // other instead of drifting into unison, and it is one animation to run.
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(TVPalette.neon)
                    .frame(width: 4, height: barHeight(index: i))
            }
        }
        .frame(height: 26)
        .shadow(color: TVPalette.neon.opacity(0.8), radius: 6)
        .onAppear { startIfNeeded() }
        .onChange(of: isAnimating) { _ in startIfNeeded() }
    }

    private func barHeight(index: Int) -> CGFloat {
        guard isAnimating else { return [10, 18, 13][index] }
        let offsets: [CGFloat] = [0, 0.33, 0.66]
        let wave = sin((phase + offsets[index]) * .pi * 2)
        return 8 + (wave + 1) / 2 * 16
    }

    private func startIfNeeded() {
        guard isAnimating else { return }
        phase = 0
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
