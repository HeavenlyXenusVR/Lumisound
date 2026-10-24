import Foundation
import Combine

/// Reacts to track changes and, when Silence Trim is enabled (Settings →
/// Audio → Silence Trim), seeks past any detected leading dead air — see
/// `SilenceTrimAnalyzer` for the actual on-device detection. Observes
/// `AudioPlayerManager.$currentSong` from the outside rather than being
/// wired into the crossfade/queue-advance engine itself — no changes
/// needed to `AudioPlayerManager+Crossfade.swift` — same reasoning as
/// `AIDJService`.
@MainActor
final class SilenceTrimService: ObservableObject {
    private static let enabledKey = "silenceTrim.enabled"
    /// Skip the seek for negligible amounts of lead-in — not worth the
    /// jump for under a third of a second.
    private static let minimumWorthTrimming: TimeInterval = 0.3

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private var cancellable: AnyCancellable?
    private weak var player: AudioPlayerManager?

    /// Mirrors `AccountService.shared`/`LibraryManager.shared` — gives
    /// non-view code (e.g. `DiagnosticsSnapshotService`) a way to reach the
    /// live instance without needing it threaded through as a parameter.
    static weak var shared: SilenceTrimService?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        Self.shared = self
    }

    func attach(player: AudioPlayerManager) {
        self.player = player
        cancellable = player.$currentSong
            .compactMap { $0 }
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] song in
                self?.handleTrackChange(to: song)
            }
    }

    private func handleTrackChange(to song: Song) {
        // Local files only — analyzing a remote stream would mean
        // downloading it just to measure silence.
        guard isEnabled, let url = song.url, url.isFileURL else { return }
        Task { [weak self] in
            let silence = await SilenceTrimAnalyzer.shared.leadingSilence(for: url)
            guard silence >= Self.minimumWorthTrimming,
                  let self, let player = self.player,
                  player.currentSong?.id == song.id,
                  // BUGFIX (reported: audio goes quiet right after a track
                  // starts, then comes back up): a cache-miss analysis
                  // decodes several seconds of audio off-thread and can
                  // resolve well after playback has already moved past the
                  // detected silence window — most often on a track's very
                  // first play, before this result is cached. Seeking at
                  // that point lands `player.seek(to:)` on its "reseek of
                  // already-playing audio" path, which mutes the node and
                  // ramps it back in to avoid a waveform-discontinuity
                  // click — but by then real, audible music is already
                  // playing, so that mute/ramp is exactly the "silent, then
                  // back to regular/boosted" dip being reported. While
                  // we're still inside the silent window there is nothing
                  // audible to protect — the node is already producing
                  // near-silence — so only trim there; once playback has
                  // caught up past it, skip the trim entirely rather than
                  // snap into content the listener is already hearing.
                  player.position < silence
            else { return }
            player.seek(to: silence)
        }
    }
}
