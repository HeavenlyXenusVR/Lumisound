import Foundation
import UIKit

// MARK: - DiagnosticsSnapshotService
//
// Periodic structured snapshot of live app state — playback, profile, the
// social system, and which settings are actually on AND having a visible
// effect — sent to the bridge's event log every `interval`. This exists
// specifically because there's no Xcode/device debugger available in this
// project's dev environment: every prior investigation (the gallery
// background stuck-icon bug, the Library reload freeze, the media scan
// stutter) started from either a lucky log line or an ad-hoc one-off dump
// added mid-investigation. This is the standing version of that same idea —
// a routine, always-on "what does a real session actually look like right
// now" readout, so the next investigation starts with data already in hand
// instead of needing its own round of diagnostic builds first.
//
// Always-on, no settings toggle — matches PerformanceMonitorService's own
// "just always runs" precedent for infrastructure-level diagnostics (that
// one covers CPU/GPU; this one covers app-level state). Skips entirely
// while backgrounded (nothing meaningful changes for a user who isn't
// looking at the app, and there's no reason to spend the network/battery).
@MainActor
enum DiagnosticsSnapshotService {
    /// "A set easy interval" — 5 minutes. Frequent enough to catch a
    /// session's real state without turning this into its own source of
    /// background chatter; every RemoteLogger call here is fire-and-forget
    /// and best-effort, so a missed tick costs nothing.
    private static let interval: TimeInterval = 5 * 60
    private static var timer: Timer?

    /// Call once from `LumisoundApp`'s `.task` — deliberately NOT `init()`
    /// (unlike `PerformanceMonitorService`, which has nothing to read yet
    /// at that point): every `.shared` singleton this function reads is a
    /// `weak var` set by that service's own `init()`, and those services
    /// are `@StateObject`s constructed when `LumisoundApp`'s `body` first
    /// evaluates — after `init()`, but before `.task` fires.
    static func start() {
        guard timer == nil else { return }
        send(reason: "app_launch") // seed one immediately rather than waiting a full interval
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { send(reason: "periodic") }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func send(reason: String) {
        guard UIApplication.shared.applicationState == .active else { return }

        let detail: [String: Any] = [
            "playback": playbackSnapshot(),
            "profile": profileSnapshot(),
            "social": socialSnapshot(),
            "settings": settingsSnapshot(),
        ]
        RemoteLogger.log(category: "diagnostics", event: "snapshot", message: reason, detail: detail)
    }

    // MARK: - Playback

    private static func playbackSnapshot() -> [String: Any] {
        guard let player = AudioPlayerManager.shared else { return ["available": false] }
        let s = player.audioSettings
        return [
            "available": true,
            "isPlaying": player.isPlaying,
            "hasCurrentSong": player.currentSong != nil,
            "queueCount": player.queue.count,
            "queueIndex": player.currentIndex,
            "positionSeconds": Int(player.position),
            "durationSeconds": Int(player.duration),
            "repeatMode": String(describing: player.repeatMode),
            "shuffleEnabled": player.shuffleEnabled,
            "autoRadioEnabled": player.autoRadioEnabled,
            "abRepeatEnabled": player.abRepeatEnabled,
            "isUsingTrackAudioSettings": player.isUsingTrackAudioSettings,
            // Whether each toggle is not just ON but actually doing
            // something right now — the distinction that matters most for
            // "is this feature working" style investigations.
            "effectsActive": [
                "8d": player.is8DActive,
                "tremolo": player.isTremoloActive,
                "vibrato": player.isVibratoActive,
                "crossfading": player.isCrossfading,
            ],
            "audioSettings": [
                "volume": s.volume,
                "speed": s.speed,
                "pitchSemitones": s.pitchSemitones,
                "equalizerEnabled": s.equalizerEnabled,
                "eqPreset": String(describing: s.eqPreset),
                "crossfadeEnabled": s.crossfadeEnabled,
                "crossfadeDuration": s.crossfadeDuration,
                "gaplessEnabled": s.gaplessEnabled,
                "replayGainEnabled": s.replayGainEnabled,
            ],
            "sleepTimer": [
                "enabledAndRunning": SleepTimerService.shared?.isActive ?? false,
                "remainingSeconds": Int(SleepTimerService.shared?.remainingSeconds ?? 0),
            ],
        ]
    }

    // MARK: - Profile

    private static func profileSnapshot() -> [String: Any] {
        guard let account = AccountService.shared else { return ["available": false] }
        return [
            "available": true,
            "isLoggedIn": account.isLoggedIn,
            "hasAvatarImageLoaded": account.avatarImage != nil,
            "hasUnlockedAchievements": (account.achievements?.totalPlays ?? 0) > 0,
            "hasAriaDailyPick": account.ariaDailyPick != nil,
            "similarListenerTrackCount": account.similarListenerTracks.count,
        ]
    }

    // MARK: - Social

    private static func socialSnapshot() -> [String: Any] {
        guard let social = SocialService.shared else { return ["available": false] }
        return [
            "available": true,
            "hasMyProfile": social.myProfile != nil,
            "friendCount": social.friends.count,
            "incomingRequestCount": social.incomingRequests.count,
            "outgoingRequestCount": social.outgoingRequests.count,
            "blockedCount": social.blockedUsers.count,
            "friendsActivityCount": social.friendsActivity.count,
            "listeningTogetherCount": social.listeningTogether.count,
        ]
    }

    // MARK: - Settings (and whether each is actually doing something)

    private static func settingsSnapshot() -> [String: Any] {
        var result: [String: Any] = [
            "reduceMotion": UserDefaults.standard.bool(forKey: "app_reduce_motion"),
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
        ]

        if let bg = BackgroundService.shared {
            result["galleryBackground"] = [
                "enabled": bg.isEnabled,
                "source": UserDefaults.standard.string(forKey: GalleryBackgroundSource.storageKey)
                    ?? GalleryBackgroundSource.photos.rawValue,
                "imageCount": bg.images.count,
                // The "is it actually doing something" signal: enabled with
                // images loaded but the shuffle timer not running means the
                // toggle is on and nothing is happening — exactly the shape
                // of bug this whole service exists to catch earlier.
                "actuallyShuffling": bg.isActive,
                "kenBurnsEnabled": bg.kenBurnsEnabled,
            ]
        }

        if let appLock = AppLockService.shared {
            result["appLock"] = [
                "enabled": appLock.isEnabled,
                "currentlyUnlocked": appLock.isUnlocked,
            ]
        }

        if let library = LibraryManager.shared {
            result["library"] = [
                "songCount": library.allSongs.count,
                "isScanning": library.isScanning,
                "playlistCount": library.playlists.count,
                "favoriteCount": library.favoriteSongIDs.count,
            ]
        }

        return result
    }
}
