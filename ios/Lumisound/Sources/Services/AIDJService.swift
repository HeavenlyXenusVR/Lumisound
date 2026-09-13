import Foundation
import AVFoundation
import Combine

/// AI DJ Mode — when enabled, briefly ducks playback volume after each
/// track change and speaks a short Aria Lumi-written transition line
/// on-device (AVSpeechSynthesizer), then restores volume and lets playback
/// continue as normal. The transition text itself comes from the bridge's
/// POST /user/ai-dj/transition (same `call_intelligence`/Gemini pipeline
/// Aria Lumi's metadata matching uses — see intelligence.py) so it stays
/// server-side and never needs an on-device model; only the speaking
/// happens locally, same reasoning as everywhere else in the app that
/// avoids sending audio anywhere.
///
/// Deliberately narrow in scope: this reacts to `AudioPlayerManager`
/// finishing a track change, the same signal `NowPlayingView` etc. already
/// observe, rather than reaching into the crossfade engine itself — no
/// changes to `AudioPlayerManager+Crossfade.swift`'s actual mixing logic.
/// Volume ducking reuses `audioSettings.volume`, the exact same knob
/// `SleepTimerService`'s fade-out already drives (see that type's
/// `getVolume`/`setVolume` closures, wired the same way from
/// `LumisoundApp.swift`), so the two features can never fight over two
/// different volume paths.
@MainActor
final class AIDJService: NSObject, ObservableObject {
    private static let enabledKey = "aiDJMode.enabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { stopSpeaking() }
        }
    }
    @Published private(set) var isSpeaking = false
    /// The most recent transition line spoken, kept only for a small
    /// "Aria just said…" caption on the Now Playing screen while
    /// `isSpeaking` is true.
    @Published private(set) var lastBlurb: String?

    weak var player: AudioPlayerManager?
    weak var account: AccountService?

    /// Same read/write-volume closure pattern as `SleepTimerService`, wired
    /// from `LumisoundApp.swift` — lets this service duck/restore playback
    /// volume without needing a direct `AudioPlayerManager` dependency.
    var getVolume: (() -> Float)?
    var setVolume: ((Float) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var cancellable: AnyCancellable?
    private var previousTitle: String?
    private var previousArtist: String?
    private var lastAnnouncedSongID: Song.ID?
    private var volumeBeforeDuck: Float = 1.0

    /// Mirrors `AccountService.shared`/`LibraryManager.shared` — gives
    /// non-view code (e.g. `DiagnosticsSnapshotService`) a way to reach the
    /// live instance without needing it threaded through as a parameter.
    static weak var shared: AIDJService?

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        super.init()
        synthesizer.delegate = self
        Self.shared = self
    }

    /// Starts observing track changes. Call once at launch after `player`
    /// and `account` are constructed (same timing as `sharePlay.player = player`
    /// in `LumisoundApp.swift`'s `.task`).
    func attach(player: AudioPlayerManager, account: AccountService) {
        self.player = player
        self.account = account
        cancellable = player.$currentSong
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] song in
                self?.handleTrackChange(to: song)
            }
    }

    private func handleTrackChange(to song: Song?) {
        defer {
            previousTitle = song?.title
            previousArtist = song?.artist
        }
        guard isEnabled, let song, let player, player.isPlaying else { return }
        guard song.id != lastAnnouncedSongID else { return }
        lastAnnouncedSongID = song.id

        let prevTitle = previousTitle
        let prevArtist = previousArtist
        Task { [weak self] in
            guard let self, let account = self.account, account.isLoggedIn else { return }
            guard let blurb = await account.fetchDJTransitionBlurb(
                nextTitle: song.title,
                nextArtist: song.artist,
                previousTitle: prevTitle,
                previousArtist: prevArtist
            ), !blurb.isEmpty else { return }
            // The track may have changed again (skip) while the request was
            // in flight — a stale blurb about the wrong song is worse than
            // silence, so bail if `currentSong` has since moved on.
            guard self.player?.currentSong?.id == song.id else { return }
            self.speak(blurb)
        }
    }

    private func speak(_ text: String) {
        guard let getVolume, let setVolume else { return }
        volumeBeforeDuck = getVolume()
        setVolume(volumeBeforeDuck * 0.25)
        isSpeaking = true
        lastBlurb = text

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    /// Immediately stops any in-progress announcement and restores volume —
    /// called when the user turns AI DJ Mode off mid-speech.
    func stopSpeaking() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension AIDJService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setVolume?(self.volumeBeforeDuck)
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setVolume?(self.volumeBeforeDuck)
            self.isSpeaking = false
        }
    }
}
