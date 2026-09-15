import SwiftUI

// MARK: - TVMiniPlayerBar
//
// Persistent "what's playing" strip pinned under the app shell, and the route
// back into the full Now Playing screen from anywhere.
//
// The full player is a `navigationDestination(for: TVPlayContext.self)`, which
// means it could only ever be reached by PICKING a track from a list. Navigate
// away and there was no way back — no indication anything was playing, and no
// way to pause, skip or reopen it without finding the original track again.
// That is the "no way to see what's now playing" problem.
//
// Design follows the platform conventions rather than inventing one:
//  - It is one focusable row, not a cluster of small controls. On tvOS every
//    focusable element costs a directional move, and a bar the user passes
//    THROUGH on the way to content is hostile. Focusing the bar and pressing
//    select opens the full player, where the transport controls already live
//    and have room to be operated comfortably.
//  - Focus is signalled by scale plus elevation (the tvOS focus idiom), not by
//    a colour change alone, which is unreliable across TV calibrations.
//  - It only exists while something is loaded, so it never takes a focus slot
//    from an empty app.
struct TVMiniPlayerBar: View {
    @ObservedObject var model: TVPlayerModel
    @ObservedObject var client: TVBridgeClient
    let token: String

    @Environment(\.isFocused) private var isFocused
    @FocusState private var focused: Bool

    private var track: TVPlayable? { model.current }

    var body: some View {
        if let track {
            NavigationLink {
                // No context: keep playing whatever is playing, just show it.
                TVPlayerView(client: client, token: token)
            } label: {
                content(for: track)
            }
            .buttonStyle(.plain)
            .focused($focused)
            .scaleEffect(focused ? 1.015 : 1)
            .shadow(color: .black.opacity(focused ? 0.55 : 0), radius: focused ? 24 : 0, y: focused ? 10 : 0)
            .animation(.easeOut(duration: 0.18), value: focused)
            .padding(.horizontal, 60)
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func content(for track: TVPlayable) -> some View {
        HStack(spacing: 22) {
            TVAuthImage(url: track.artworkURL, token: track.authToken) {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)

            // State, not a control: the bar is a single focusable target, so
            // these communicate rather than invite a press.
            HStack(spacing: 16) {
                if model.isBuffering {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: model.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(focused ? 0.35 : 0.12), lineWidth: 1)
                // Progress hairline along the bottom edge — the only honest way
                // to show position without stealing a focusable control.
                GeometryReader { geo in
                    Capsule()
                        .fill(.tint)
                        .frame(width: geo.size.width * progressFraction, height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)
            }
        }
    }

    private var progressFraction: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.position / model.duration))
    }
}
