import SwiftUI

// MARK: - TVLyricsPanel
//
// Full-screen synced-lyrics overlay for Now Playing — same "last line whose
// timestamp <= currentPosition" highlighting and auto-scroll-to-center
// behavior as iOS's LyricsView.swift, sized up for 10-foot viewing.

struct TVLyricsPanel: View {
    let lines: [TVLyricLine]
    let currentPosition: TimeInterval
    let isPlaying: Bool
    let isLoading: Bool
    let onClose: () -> Void

    // tvOS's focus engine never automatically moves focus into a view that
    // appears on top of already-focused content (this panel is drawn in
    // the same ZStack as Now Playing's transport controls, not presented
    // as a real `.sheet`) — without this, the panel shows up but the Siri
    // Remote's focus silently stays on whatever transport/utility button
    // opened it, so nothing in the panel itself is reachable. Forcing
    // focus onto the close button the moment the panel appears is what
    // actually makes it interactive.
    @FocusState private var closeButtonFocused: Bool

    private var currentLineIndex: Int? {
        var result: Int?
        for (index, line) in lines.enumerated() {
            if line.time <= currentPosition {
                result = index
            } else {
                break
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 14) {
                    TVPlayingMeter(isAnimating: isPlaying)
                    Text("LYRICS")
                        .font(TVType.eyebrow)
                        .tracking(2.6)
                        .foregroundStyle(TVPalette.neonAlt)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    TVIconButtonLabel(systemImage: "xmark")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focused($closeButtonFocused)
            }
            .padding(.horizontal, 80)
            .padding(.top, 56)
            .padding(.bottom, 10)

            if isLoading {
                TVLoadingBars(height: 70).frame(maxHeight: .infinity)
            } else if lines.isEmpty {
                TVEmptyState(systemImage: "text.badge.xmark",
                             title: "No lyrics for this one",
                             message: "Synced lyrics weren't found for this track.")
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                lyricsScroll
                    // Fade lines out toward the top and bottom edges rather
                    // than cutting them off mid-word.
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.18),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                TVPalette.ground.opacity(0.82)
                RadialGradient(colors: [TVPalette.violet.opacity(0.25), .clear],
                               center: .top, startRadius: 0, endRadius: 900)
            }
        }
        .focusSection()
        .onAppear { closeButtonFocused = true }
        .ignoresSafeArea()
    }

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 34) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        lyricLine(line: line, isCurrent: index == currentLineIndex)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 220)
                .padding(.horizontal, 140)
            }
            .onChange(of: currentLineIndex) { newIndex in
                scrollToCurrentLine(proxy: proxy, index: newIndex, animated: isPlaying)
            }
            .onChange(of: isPlaying) { playing in
                // Re-anchor without animation the moment playback resumes so the
                // highlighted line doesn't visibly drift against a stale target.
                if playing {
                    scrollToCurrentLine(proxy: proxy, index: currentLineIndex, animated: false)
                }
            }
            .onAppear {
                scrollToCurrentLine(proxy: proxy, index: currentLineIndex, animated: false)
            }
        }
    }

    private func scrollToCurrentLine(proxy: ScrollViewProxy, index: Int?, animated: Bool) {
        guard let idx = index, lines.indices.contains(idx) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(lines[idx].id, anchor: .center)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(lines[idx].id, anchor: .center)
            }
        }
    }

    private func lyricLine(line: TVLyricLine, isCurrent: Bool) -> some View {
        Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: isCurrent ? 50 : 40, weight: .bold, design: .rounded))
            .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.3))
            .shadow(color: isCurrent ? TVPalette.violet.opacity(0.6) : .clear, radius: 20)
            .multilineTextAlignment(.center)
            .scaleEffect(isCurrent ? 1.03 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCurrent)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
