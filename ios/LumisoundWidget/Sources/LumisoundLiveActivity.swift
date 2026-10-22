import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

@available(iOS 16.1, *)
private func liveActivityFormatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

@available(iOS 16.1, *)
private func liveActivityArtwork() -> UIImage? {
    let appGroupID = AppGroup.id
    guard let ud = UserDefaults(suiteName: appGroupID),
          let relPath = ud.string(forKey: "widget_artwork_path"),
          let container = FileManager.default.containerURL(
              forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
    return UIImage(contentsOfFile: container.appendingPathComponent(relPath).path)
}

@available(iOS 16.1, *)
private struct LiveActivityArtworkView: View {
    let image: UIImage?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 8

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.gray.opacity(0.35))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.7))
                        .font(.system(size: size * 0.4))
                )
        }
    }
}

@available(iOS 16.1, *)
private struct LiveActivityProgressBar: View {
    let state: LumisoundActivityAttributes.ContentState
    var tint: Color = .cyan

    var body: some View {
        Group {
            if state.isPlaying, state.duration > 0 {
                // Self-advancing, same mechanism as the elapsed-time `Text
                // (timerInterval:)` label elsewhere in this file: the system
                // (not this process) animates the fill continuously between
                // `LiveActivityManager` pushes, from `state.trackRange`'s
                // fixed anchor. A manually-computed `position / duration`
                // fraction (the old implementation) is a snapshot that only
                // moves when a NEW ContentState is pushed — since nothing
                // pushes on a steady playback cadence (pushes are event-
                // driven: track change/play-pause/seek/favorite), that bar
                // sat frozen at wherever it was for the entire rest of the
                // track, which is the literal "stuck a few seconds (or
                // minutes) behind" symptom. `ProgressView(timerInterval:)`
                // needs no extra pushes to stay accurate, so this costs
                // nothing extra in battery/network over the old approach.
                ProgressView(timerInterval: state.trackRange, countsDown: false)
                    .progressViewStyle(.linear)
                    .tint(tint)
            } else {
                // Paused (or no duration yet): there is nothing to animate
                // toward, so fall back to the old static fraction-based fill
                // anchored at the frozen position.
                GeometryReader { geo in
                    let fraction = state.duration > 0 ? min(1, max(0, state.position / state.duration)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(tint)
                            .frame(width: geo.size.width * fraction)
                    }
                }
            }
        }
        .frame(height: 3)
    }
}

@available(iOS 16.1, *)
private struct LiveActivityTransportControls: View {
    let state: LumisoundActivityAttributes.ContentState
    var iconSize: CGFloat = 20
    var spacing: CGFloat = 26
    /// The Lock Screen banner has room for a 4th button; the Dynamic
    /// Island's compact expanded-region slots don't — keep the heart button
    /// exclusive to the roomier presentation rather than cramming every
    /// region.
    var showsFavorite: Bool = false

    var body: some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: spacing) {
                Button(intent: SkipPreviousIntent()) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: iconSize * 0.85, weight: .medium))
                }
                .buttonStyle(.plain)

                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                }
                .buttonStyle(.plain)

                Button(intent: SkipNextIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: iconSize * 0.85, weight: .medium))
                }
                .buttonStyle(.plain)

                if showsFavorite {
                    Button(intent: ToggleFavoriteIntent()) {
                        Image(systemName: state.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: iconSize * 0.8, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.isFavorite ? Color.pink : Color.white)
                }
            }
            .foregroundStyle(.white)
        } else {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// Lock Screen banner + Dynamic Island presentation for the current track.
/// Content comes from `LumisoundActivityAttributes.ContentState`, pushed by
/// `LiveActivityManager` in the host app; artwork is read straight off the
/// shared App Group container, same as `LumisoundWidgetProvider` does.
@available(iOS 16.1, *)
struct LumisoundLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LumisoundActivityAttributes.self) { context in
            // MARK: Lock Screen / banner
            let state = context.state
            let artwork = liveActivityArtwork()
            HStack(spacing: 12) {
                LiveActivityArtworkView(image: artwork, size: 50, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title.isEmpty ? "Nothing Playing" : state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)

                    if !state.title.isEmpty {
                        LiveActivityProgressBar(state: state)
                        HStack {
                            if state.isPlaying, state.duration > 0 {
                                Text(timerInterval: state.trackRange, countsDown: false, showsHours: false)
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.7))
                            } else {
                                Text(liveActivityFormatTime(state.position))
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer()
                            Text(liveActivityFormatTime(state.duration))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                Spacer(minLength: 0)

                LiveActivityTransportControls(state: state, showsFavorite: true)
            }
            .padding(14)
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            let state = context.state
            let artwork = liveActivityArtwork()

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityArtworkView(image: artwork, size: 40, cornerRadius: 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveActivityTransportControls(state: state, iconSize: 16, spacing: 16)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.title.isEmpty ? "Nothing Playing" : state.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(state.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                        if !state.title.isEmpty {
                            LiveActivityProgressBar(state: state)
                        }
                    }
                }
            } compactLeading: {
                LiveActivityArtworkView(image: artwork, size: 20, cornerRadius: 4)
            } compactTrailing: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(.cyan)
                    .font(.system(size: 13, weight: .semibold))
            } minimal: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(.cyan)
            }
            .widgetURL(nil)
            .keylineTint(.cyan)
        }
    }
}
