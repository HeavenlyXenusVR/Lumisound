import SwiftUI

// MARK: - TVVinylDeck
//
// Circular artwork on a record: the album art as the label, dark vinyl around
// it with concentric grooves, a bright spindle, and a tonearm resting on the
// edge. It turns while the track plays and eases to a stop when it pauses.
//
// It is not decoration for its own sake. A square cover tells you nothing about
// whether audio is actually running — the old panel showed an identical frame
// whether playing, paused, or silently stalled mid-buffer. A record that spins
// is a state readout you can check from across the room, and it is bound to the
// same `isPlaying` the transport is, so it cannot disagree with reality.
struct TVVinylDeck: View {
    let artworkURL: URL?
    let token: String?
    let isPlaying: Bool
    var diameter: CGFloat = 320

    @State private var angle: Double = 0
    /// Drives rotation from a timer rather than a `repeatForever` animation.
    /// `repeatForever` cannot be stopped mid-flight — removing it snaps the
    /// rotation back to zero, so pausing made the record jump rather than
    /// settle. Stepping the angle keeps it wherever it stopped, which is what
    /// a real deck does.
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Vinyl body.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.16), Color(white: 0.04)],
                        center: .center, startRadius: diameter * 0.16, endRadius: diameter * 0.5
                    )
                )

            // Grooves. Six rings is enough to read as a record at 10 feet;
            // more is invisible detail rendered every frame for nothing.
            ForEach(0..<6, id: \.self) { i in
                Circle()
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                    .padding(diameter * (0.09 + Double(i) * 0.035))
            }

            // Sheen — a single bright arc so the disc reads as a lit surface
            // rather than a flat dark circle.
            Circle()
                .trim(from: 0.06, to: 0.20)
                .stroke(
                    LinearGradient(colors: [.white.opacity(0.28), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: diameter * 0.30)
                )
                .blur(radius: 26)
                .allowsHitTesting(false)

            // The label: artwork, clipped to the centre of the record.
            TVAuthImage(url: artworkURL, token: token) {
                TVArtPlaceholder(systemImage: "music.note", iconScale: 1.1)
            }
            .frame(width: diameter * 0.52, height: diameter * 0.52)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }

            // Spindle.
            Circle()
                .fill(TVPalette.neon)
                .frame(width: diameter * 0.045, height: diameter * 0.045)
                .shadow(color: TVPalette.neon, radius: 10)
        }
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(angle))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
        // Tonearm sits OUTSIDE the rotation, or it would spin with the record.
        .overlay(alignment: .topTrailing) {
            Capsule()
                .fill(LinearGradient(colors: [TVPalette.neon, TVPalette.neonAlt],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 9, height: diameter * 0.42)
                .rotationEffect(.degrees(isPlaying ? 28 : 12), anchor: .top)
                .offset(x: -diameter * 0.10, y: -diameter * 0.04)
                .shadow(color: TVPalette.neon.opacity(0.6), radius: 10)
                .animation(.easeInOut(duration: 0.5), value: isPlaying)
        }
        .onReceive(tick) { _ in
            guard isPlaying else { return }
            // ~8 rpm — slow enough to read as motion, not as a spinner.
            angle = (angle + 1.6).truncatingRemainder(dividingBy: 360)
        }
    }
}

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
// The column exists ONLY when something is playing, and the shell composes it
// with a plain `if` — no inset, no empty branch, no focus section around
// nothing. When there is nothing to show, there is no view at all.
struct TVNowPlayingPanel: View {
    @ObservedObject var model: TVPlayerModel
    @ObservedObject var client: TVBridgeClient
    let token: String

    static let width: CGFloat = 560

    private var track: TVPlayable? { model.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header

            if let track {
                // The deck opens the full-screen player. It is the panel's
                // single large target, which is the right shape for a remote:
                // one confident press rather than a hunt among small controls.
                NavigationLink {
                    TVPlayerView(client: client, token: token)
                } label: {
                    TVDeckButtonLabel(
                        artworkURL: track.artworkURL,
                        token: track.authToken,
                        isPlaying: model.isPlaying
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title)
                        .font(TVType.rowTitle)
                        .lineLimit(2)
                    Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                        .font(TVType.rowDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                lyrics

                transport
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 44)
        // maxHeight as well as width, and the content is top-aligned inside it.
        // Without this the VStack sized to its content, so the gradient below
        // covered only the middle band of the column — the floating rectangle
        // with hard top and bottom edges the column showed on a real display.
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            LinearGradient(
                colors: [TVPalette.ground.opacity(0.35), TVPalette.surface.opacity(0.9)],
                startPoint: .leading, endPoint: .trailing
            )
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [TVPalette.neonAlt.opacity(0.35), TVPalette.neon.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 1.5)
            }
        }
        .ignoresSafeArea(edges: .vertical)
        .focusSection()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isPlaying ? TVPalette.neon : Color.white.opacity(0.3))
                .frame(width: 9, height: 9)
                .shadow(color: model.isPlaying ? TVPalette.neon : .clear, radius: 7)
            Text(model.isBuffering ? "BUFFERING" : (model.isPlaying ? "NOW PLAYING" : "PAUSED"))
                .font(TVType.eyebrow)
                .tracking(2.2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if model.queue.count > 1 {
                Text("\(model.currentIndex + 1)/\(model.queue.count)")
                    .font(TVType.meta)
                    .foregroundStyle(.secondary)
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
                        .font(.system(size: i == idx ? 25 : 21,
                                      weight: i == idx ? .semibold : .regular))
                        .foregroundStyle(i == idx ? Color.white : Color.white.opacity(0.38))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.25), value: idx)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .tvNeonCard(cornerRadius: TVMetrics.panelCorner)
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
        VStack(spacing: 18) {
            VStack(spacing: 7) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(LinearGradient(colors: [TVPalette.neon, TVPalette.neonAlt],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * progress))
                            .shadow(color: TVPalette.neon.opacity(0.7), radius: 8)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text(model.position.tvDurationText ?? "0:00")
                    Spacer()
                    Text(model.duration.tvDurationText ?? "--:--")
                }
                .font(TVType.meta)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 26) {
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
    }
}

/// Deck plus its focus treatment. Split out so `@Environment(\.isFocused)` is
/// read inside the `NavigationLink`'s label, where tvOS actually populates it.
private struct TVDeckButtonLabel: View {
    let artworkURL: URL?
    let token: String?
    let isPlaying: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        TVVinylDeck(artworkURL: artworkURL, token: token, isPlaying: isPlaying, diameter: 330)
            .scaleEffect(isFocused ? 1.05 : 1)
            .overlay {
                Circle()
                    .strokeBorder(TVPalette.neon.opacity(isFocused ? 0.95 : 0), lineWidth: 3)
                    .shadow(color: TVPalette.neon.opacity(isFocused ? 0.8 : 0), radius: 22)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isFocused)
    }
}

private struct TVTransportButtonLabel: View {
    let symbol: String
    let primary: Bool
    @Environment(\.isFocused) private var isFocused

    private var size: CGFloat { primary ? 76 : 60 }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: primary ? 30 : 24, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background {
                Circle().fill(
                    isFocused ? AnyShapeStyle(Color.white)
                    : primary
                        ? AnyShapeStyle(LinearGradient(colors: [TVPalette.neon, TVPalette.neonAlt],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.white.opacity(0.12))
                )
            }
            .shadow(color: TVPalette.neon.opacity(isFocused ? 0.8 : (primary ? 0.45 : 0)),
                    radius: isFocused ? 22 : 12)
            .scaleEffect(isFocused ? 1.12 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isFocused)
    }
}
