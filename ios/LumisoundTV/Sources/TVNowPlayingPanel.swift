import SwiftUI

// MARK: - TVNowPlayingPanel
//
// A persistent right-hand column showing what's playing: the deck, the track,
// live lyrics, and transport.
//
// This replaces `TVMiniPlayerBar`, the thin strip previously pinned across the
// bottom of the shell. The strip had two problems the column does not:
//
//   - It was one focusable row with no controls, so pausing meant opening the
//     full player first. The column has real transport in reach at all times.
//   - It sat in a `safeAreaInset` across the bottom, which put it in the path of
//     every downward move out of a list, and rendered an empty view when nothing
//     was playing. That empty branch is what made v1.7.0 relaunch in a loop.
//
// Prism pass: the vinyl deck is gone in favour of the cover itself, lit from
// behind, with a live meter in the header to say whether audio is running.
// Transport sits directly under the title and lyrics follow it, so the
// controls never move as lyric lines come and go.
//
// The column exists ONLY when something is playing, and the shell composes it
// with a plain `if` — no inset, no empty branch, no focus section around
// nothing. When there is nothing to show, there is no view at all.
struct TVNowPlayingPanel: View {
    @ObservedObject var model: TVPlayerModel
    @ObservedObject var client: TVBridgeClient
    @ObservedObject private var aria = TVAria.shared
    @ObservedObject private var settings = TVAudioSettings.shared
    let token: String

    static let width: CGFloat = 430

    private var track: TVPlayable? { model.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            if let track {
                // The artwork opens the full-screen player. It is the panel's
                // single large target, which is the right shape for a remote:
                // one confident press rather than a hunt among small controls.
                NavigationLink {
                    TVPlayerView(client: client, token: token)
                } label: {
                    TVPanelArtworkLabel(
                        artworkURL: track.artworkURL,
                        token: track.authToken,
                        isPlaying: model.isPlaying,
                        isBuffering: model.isBuffering
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title)
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                        .font(TVType.rowDetail)
                        .foregroundStyle(TVPalette.textSecondary)
                        .lineLimit(1)
                }
                .id(track.id)
                .transition(.opacity)

                // Aria's handover, above the lyrics — it is about the track
                // that just started, so it belongs next to its title rather
                // than buried under the transport.
                if settings.djTransitions, let blurb = aria.currentBlurb {
                    TVAriaBlurbView(text: blurb)
                }

                transport

                lyrics
            }
        }
        .animation(.easeOut(duration: 0.35), value: track?.id)
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .frame(width: Self.width)
        // A CARD, not a column.
        //
        // Two earlier attempts both got this wrong in opposite directions. The
        // first let the stack size to its content while painting a full-bleed
        // background, so the gradient stopped wherever the content did and read
        // as a rectangle accidentally floating at the right edge. The fix for
        // that — fill the height — was worse: a full-height slab of solid colour
        // down the whole right side, which buries a sixth of the screen under
        // chrome on every tab and competes with the content for attention.
        //
        // It is a self-contained card pinned to the top right instead: bounded
        // on every side, obviously deliberate, and leaving the rest of the
        // column free so the backdrop and the content below both stay visible.
        .tvGlassPanel(cornerRadius: 36)
        .padding(.trailing, 40)
        .padding(.top, 40)
        // Top-aligned within the full height: the card keeps its own size and
        // sits at the top right rather than stretching to fill.
        .frame(maxHeight: .infinity, alignment: .top)
        .focusSection()
    }

    private var header: some View {
        HStack(spacing: 12) {
            TVPlayingMeter(isAnimating: model.isPlaying && !model.isBuffering)
                .scaleEffect(0.8)
            Text(model.isBuffering ? "BUFFERING" : (model.isPlaying ? "NOW PLAYING" : "PAUSED"))
                .font(TVType.eyebrow)
                .tracking(2.4)
                .foregroundStyle(model.isPlaying ? TVPalette.neonAlt : TVPalette.textTertiary)
            Spacer(minLength: 0)
            if model.queue.count > 1 {
                Text("\(model.currentIndex + 1) of \(model.queue.count)")
                    .font(TVType.meta)
                    .foregroundStyle(TVPalette.textTertiary)
            }
        }
    }

    /// A short scrolling window of lyrics with the current line lit. Only three
    /// lines are shown: this is a glanceable companion to the deck, not the
    /// full-screen lyrics view, which still lives in the player behind it.
    @ViewBuilder
    private var lyrics: some View {
        if model.lyrics.isEmpty {
            EmptyView()
        } else {
            let idx = currentLyricIndex
            VStack(alignment: .leading, spacing: 10) {
                ForEach(visibleLyricRange(around: idx), id: \.self) { i in
                    Text(model.lyrics[i].text)
                        .font(.system(size: i == idx ? 24 : 20,
                                      weight: i == idx ? .bold : .medium, design: .rounded))
                        .foregroundStyle(i == idx ? Color.white : Color.white.opacity(0.32))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.25), value: idx)
                }
            }
            // Fixed and clipped for the same reason as the full player's — the
            // window is a ForEach over changing indices, so lines animate in and
            // out and were drawn past the card's edge mid-transition.
            .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
            .clipped()
            .padding(.top, 4)
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .offset(y: -12)
            }
        }
    }

    /// Index of the last lyric line whose timestamp has passed, or -1 before the
    /// first one. Linear scan: lyric arrays are a few hundred entries at most and
    /// this runs once per render, not per line.
    private var currentLyricIndex: Int {
        var result = -1
        for (i, line) in model.lyrics.enumerated() {
            if line.time <= model.position { result = i } else { break }
        }
        return result
    }

    /// Three lines centred on the current one, clamped to the array's bounds so
    /// the block keeps its height at the very start and end of a song.
    private func visibleLyricRange(around index: Int) -> [Int] {
        let count = model.lyrics.count
        guard count > 0 else { return [] }
        let centre = max(0, index)
        let start = max(0, min(centre - 1, count - 3))
        let end = min(count - 1, start + 2)
        return Array(start...end)
    }

    private var transport: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(TVPalette.brandHorizontal)
                            .frame(width: max(0, geo.size.width * progress))
                            .shadow(color: TVPalette.violet.opacity(0.6), radius: 8)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text(model.position.tvDurationText ?? "0:00")
                    Spacer()
                    Text(model.duration.tvDurationText ?? "--:--")
                }
                .font(TVType.meta)
                .foregroundStyle(TVPalette.textTertiary)
            }

            HStack(spacing: 30) {
                transportButton("backward.fill") { model.previous() }
                transportButton(model.isPlaying ? "pause.fill" : "play.fill", primary: true) {
                    model.togglePlayPause()
                }
                transportButton("forward.fill") { model.next() }
            }
        }
    }

    private var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.position / model.duration))
    }

    private func transportButton(_ symbol: String, primary: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TVTransportButtonLabel(symbol: symbol, primary: primary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// The panel's artwork, as the button that opens the full player.
///
/// Replaces the spinning record. The record did one useful thing — it showed
/// whether audio was actually running — and that job now belongs to the
/// header's live meter, which every music app uses for exactly that. What the
/// record cost was most of the cover: a square album rendered as a small round
/// label in the middle of a dark disc.
private struct TVPanelArtworkLabel: View {
    let artworkURL: URL?
    let token: String?
    let isPlaying: Bool
    let isBuffering: Bool
    @Environment(\.isFocused) private var isFocused

    private let side: CGFloat = 300

    var body: some View {
        ZStack {
            // Light cast by the cover itself, brightest while playing.
            TVAuthImage(url: artworkURL, token: token) { Color.clear }
                .frame(width: side, height: side)
                .blur(radius: 40)
                .saturation(1.5)
                .opacity(isPlaying ? 0.7 : 0.3)
                .scaleEffect(1.05)

            TVAuthImage(url: artworkURL, token: token) {
                TVArtPlaceholder(systemImage: "music.note", iconScale: 1.4)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(isFocused ? AnyShapeStyle(TVPalette.brand)
                                  : AnyShapeStyle(Color.white.opacity(0.12)),
                                  lineWidth: isFocused ? 4 : 1)
            }
            .overlay {
                if isBuffering {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.black.opacity(0.45))
                        TVLoadingBars(height: 46)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if isFocused {
                    Label("Open Player", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white))
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
        }
        .scaleEffect(isFocused ? 1.05 : (isPlaying ? 1 : 0.94))
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: isFocused)
        .animation(.easeInOut(duration: 0.5), value: isPlaying)
    }
}

private struct TVTransportButtonLabel: View {
    let symbol: String
    let primary: Bool
    @Environment(\.isFocused) private var isFocused

    private var size: CGFloat { primary ? 80 : 60 }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: primary ? 30 : 22, weight: .bold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background {
                if isFocused {
                    Circle().fill(Color.white)
                } else if primary {
                    Circle().fill(TVPalette.brand)
                } else {
                    Circle().fill(Color.white.opacity(0.1))
                }
            }
            .shadow(color: isFocused ? .white.opacity(0.3)
                        : (primary ? TVPalette.violet.opacity(0.5) : .clear),
                    radius: isFocused ? 20 : 14, y: 6)
            .scaleEffect(isFocused ? 1.12 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isFocused)
    }
}
