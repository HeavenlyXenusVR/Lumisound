@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - AVPlayer fallback (Opus / WebM / OGG)

    /// Records an AVPlayer load/playback failure and either advances to the next track or, if
    /// failures are arriving in a tight loop (4+ within 5 seconds — e.g. a stale stream URL that
    /// fails instantly and `repeatMode == .one`/`.all` keeps re-triggering the same failure),
    /// stops playback entirely instead of spinning forever.
    func handleLoadFailure(message: String, userFacingMessage: String, retryURL: URL? = nil) {
        appError(message, category: "audio")
        tearDownOpusPlayer()
        isPlaying = false
        errorMessage = userFacingMessage

        // A local file that's simply GONE (confirmed via LumisoundLockFormat
        // .unlock's now-specific "no such file" error — see its doc comment)
        // is unrecoverable no matter how many playback backends are tried —
        // AVAudioFile and this AVPlayer fallback both fail identically
        // against a source that doesn't exist, so retrying/skipping alone
        // just leaves a permanently-dead entry sitting in the library until
        // someone happens to run a full rescan. Trigger one now — cheap,
        // and self-heals by dropping the stale Song (or picking it back up
        // if this was a transient move/replace) rather than leaving a
        // library entry that will fail every future play attempt the same way.
        if let deadSong = currentSong, let url = deadSong.url, url.isFileURL,
           !FileManager.default.fileExists(atPath: url.path) {
            appWarn("handleLoadFailure: \"\(deadSong.displayName)\" backing file is missing — triggering a library rescan to self-heal", category: "audio")
            Task { await LibraryManager.shared?.scanLocalDocumentsAsync() }
            // The rescan above fixes LibraryManager's OWN song list, but does
            // nothing for a copy of this same dead Song sitting in THIS
            // player's active `queue` — struct value copies, not references,
            // so a library-side fix never reaches an already-built queue.
            // Left alone, repeat/replay or the natural loop-back to this
            // index just hits the identical missing file again next time
            // around — which is exactly what field logs showed: the same
            // handful of dead entries cycling every single loop instead of
            // being dropped after the first failure. Strip it directly here
            // (queue mutation only, no `playCurrent` side effect) and let
            // this function's own `skipToNext()` below decide what plays
            // from the now-cleaned queue.
            if let idx = queue.firstIndex(where: { $0.id == deadSong.id }) {
                queue.remove(at: idx)
                if idx < currentIndex { currentIndex -= 1 }
                currentIndex = min(currentIndex, max(queue.count - 1, 0))
            }
        }

        // `errorMessage` only has a visible home on StreamSearchView and
        // deep in Settings → Audio (see their `.onChange(of: player
        // .errorMessage)` handlers) — playing from the Library/Playlists/
        // Folders tabs (the primary way anyone plays their own downloaded
        // music) surfaced NOTHING on a load failure: the track just
        // silently skipped to whatever's next, which reads as "tapping a
        // song plays a different one for no reason" rather than "this file
        // is broken." ToastCenter is visible from every screen (mounted
        // once in ContentView), so route the same failure there too, named
        // to the actual track that failed rather than a bare generic
        // message.
        let failedTrackName = currentSong?.displayName
        let now = Date()
        recentLoadFailureTimestamps.append(now)
        recentLoadFailureTimestamps.removeAll { now.timeIntervalSince($0) > 5 }

        if recentLoadFailureTimestamps.count >= 4 {
            recentLoadFailureTimestamps.removeAll()
            appError("Stopping playback after repeated track-load failures in a short window", category: "audio")
            errorMessage = "Playback stopped after repeated errors."
            ToastCenter.shared.show("Playback stopped after repeated errors", category: .error, icon: "exclamationmark.triangle.fill")
            stop()
            return
        }

        // One automatic retry for remote streams only — a corrupt local file
        // (also routed through this same handler, see scheduleWithOpusPlayer's
        // callers) fails identically every time, but a bridge stream-proxy
        // hiccup (yt-dlp extraction timeout, concurrency-slot contention —
        // see YTDLP_MAX_CONCURRENT server-side) often succeeds seconds later.
        if let retryURL, !retryURL.isFileURL, !opusRetriedThisLoad {
            opusRetriedThisLoad = true
            let retrySongID = currentSong?.id
            let retryPosition = position
            appWarn("Retrying stream load once after failure: \(retryURL.lastPathComponent)", category: "audio")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.currentSong?.id == retrySongID else { return }
                // scheduleWithOpusPlayer only starts the player's rate if
                // `isPlaying` is already true (the invariant its normal
                // caller, playCurrent, sets up before scheduling) — this
                // retry bypasses that caller, so it must set it itself.
                self.isPlaying = true
                self.scheduleWithOpusPlayer(url: retryURL, startTime: retryPosition)
            }
            return
        }

        if let failedTrackName {
            ToastCenter.shared.show("Couldn't play \"\(failedTrackName)\" — skipping", category: .error, icon: "exclamationmark.triangle.fill")
        }
        skipToNext()
    }

    /// `error?.localizedDescription` alone is frequently a useless generic
    /// string ("The operation could not be completed") that doesn't say
    /// *why* — the actually-informative reason usually sits one level down
    /// in `NSUnderlyingErrorKey` (e.g. a specific `NSURLErrorDomain` code
    /// like -1100 "resource unavailable" for an expired stream URL, or
    /// -1009 "offline"). Walking that chain is what made this class of
    /// failure undiagnosable from the DB event log alone up to now — every
    /// occurrence just said the same unhelpful generic sentence.
    static func describeLoadError(_ error: Error?) -> String {
        guard let error else { return "unknown error" }
        let nsError = error as NSError
        var parts = ["\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"]
        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        while let inner = underlying {
            parts.append("\(inner.domain) \(inner.code): \(inner.localizedDescription)")
            underlying = inner.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " ← ")
    }

    /// Used when AVAssetReader/AVAssetExportSession cannot decode the file (e.g. Ogg/Opus container).
    /// AVPlayer has access to iOS's full codec pipeline and can always play .opus files.
    /// Basic play/pause/seek/volume/speed work (speed via `.rate` + `.spectral`
    /// pitch algorithm — see `applyAudioSettings`). EQ, pitch shift, ReplayGain,
    /// 8D, crossfade, gapless, and reverb need the AVAudioEngine graph and do not apply.
    func scheduleWithOpusPlayer(url: URL, startTime: TimeInterval) {
        tearDownOpusPlayer()
        MusicHapticsService.shared.updatePlayback(
            enabled: false,
            isPlaying: false,
            engineAvailable: false
        )

        // Stop any engine nodes that were started optimistically in playCurrent().
        primaryNode.stop()
        secondaryNode.stop()

        // See LumisoundExclusiveExtensionService.playableURL's doc comment —
        // this is the fallback AVAudioFile itself falls back to, so it needs
        // the same `.lms`-URL resolution or it can fail for the identical
        // reason right behind it (a no-op for a non-`.lms` `url`, including
        // every remote/streamed one).
        let playableSourceURL = LumisoundExclusiveExtensionService.playableURL(for: url)
        // Personal Cloud Library streams (and any other authenticated bridge
        // route) need `currentSong.httpHeaders`' Bearer token on every
        // request, same as `downloadAndSchedule`'s URLSession fetch above —
        // but `AVPlayerItem(url:)` has no way to attach custom headers at
        // all, so this fallback was silently dropping Authorization on the
        // floor for every http/https stream that reached it (the normal
        // downloadAndSchedule failure path, or a remote opus/webm/ogg URL).
        // The bridge then answered with a 401/auth-challenge body, which
        // AVPlayer surfaced as it tried to decode that body as audio:
        // NSURLErrorDomain -1013 (userAuthenticationRequired) chained to an
        // underlying NSOSStatusErrorDomain decode error — confirmed in field
        // logs (`ios_app_logs`, category "audio") as repeated bursts of
        // exactly that pairing, several in under 5s each time, which is also
        // why they escalated straight to "Stopping playback after repeated
        // track-load failures" instead of just one skip. Building the asset
        // with the "AVURLAssetHTTPHeaderFieldsKey" options key (the
        // documented way to attach headers AVPlayerItem's own initializer
        // can't) fixes it; a no-op for anything with no headers to send
        // (local files, unauthenticated streams). Passed as a raw string
        // literal rather than the `AVURLAssetHTTPHeaderFieldsKey` global —
        // that symbol isn't exposed in this SDK's Swift overlay (CI failed
        // with "cannot find ... in scope" against Xcode 26.6/iOS 26.5), but
        // the options dictionary is a plain `[String: Any]`, so the
        // documented key string works regardless of whether the overlay
        // re-exports a matching constant.
        let isRemote = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        let asset: AVURLAsset
        if isRemote, let headers = currentSong?.httpHeaders, !headers.isEmpty {
            asset = AVURLAsset(url: playableSourceURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: playableSourceURL)
        }
        let item = AVPlayerItem(asset: asset)
        // Pitch-preserving time stretch — without this, AVPlayer's default
        // `.varispeed` algorithm ties pitch to rate (chipmunk/slow-mo effect),
        // which made the Speed slider feel "broken" for streamed/opus tracks.
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        player.volume = audioSettings.volume
        opusPlayer = player

        // Load duration asynchronously (AVPlayerItem duration may be unknown at creation).
        Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            if let dur = try? await asset.load(.duration), !dur.seconds.isNaN, dur.seconds > 0 {
                self.duration = dur.seconds
                self.updateNowPlaying()
            }
        }

        // Position tracking — replaces the AVAudioEngine timer path.
        opusTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.position = time.seconds
            // AB Repeat
            if self.abRepeatEnabled,
               let start = self.abRepeatStart,
               let end   = self.abRepeatEnd,
               time.seconds >= end {
                self.opusPlayer?.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                self.position = start
            }
            // Keep lock screen / Apple Watch elapsed time in sync (see timerTick).
            self.updateNowPlaying()
        }

        // Track completion → advances to next song normally.
        opusEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackEnded() }
        }

        if startTime > 0 {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }

        // Detect AVPlayer item failures (e.g. expired stream URL, unsupported format).
        opusStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .failed {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let detail = Self.describeLoadError(item.error)
                    // Telemetry, not just a local log line. A streaming failure
                    // is invisible from the outside — the user sees a toast
                    // saying a track was skipped and nothing that says why, and
                    // `appWarn`/`appLog` only reach ios_app_logs as free text
                    // that has to be grepped. Structured fields here mean the
                    // failure is queryable by cause: an auth rejection
                    // (NSURLErrorUserAuthenticationRequired, -1013) looks
                    // nothing like an expired CDN URL or a dead video, but all
                    // three previously surfaced as the same "Couldn't play"
                    // toast. The bug that prompted this — the stream proxy's
                    // Authorization header missing its "Bearer " prefix, so
                    // EVERY streamed track 401'd — would have been obvious
                    // immediately from an errorCode breakdown.
                    let nsError = item.error as NSError?
                    RemoteLogger.logError(
                        category: "streaming",
                        event: "stream_load_failed",
                        message: detail,
                        detail: [
                            "errorDomain": nsError?.domain ?? "unknown",
                            "errorCode": nsError?.code ?? 0,
                            // Whether the player was pointed at the bridge's
                            // own proxy or a direct CDN URL — the two fail for
                            // completely different reasons.
                            "viaProxy": url.path.contains("/api/stream/proxy"),
                            "isRemote": !url.isFileURL,
                            // Was an auth header attached at all? Distinguishes
                            // "we sent nothing" from "what we sent was rejected".
                            "hadAuthHeader": self.currentSong?.httpHeaders?["Authorization"] != nil,
                            "consecutiveFailures": self.recentLoadFailureTimestamps.count + 1,
                        ]
                    )
                    self.handleLoadFailure(
                        message: "AVPlayer failed to load track — skipping. \(detail)",
                        userFacingMessage: "Could not play this track.",
                        retryURL: url
                    )
                }
            } else if item.status == .readyToPlay {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.recentLoadFailureTimestamps.removeAll()
                    // A confirmed-good load means any FUTURE failure on this
                    // track is a new, distinct problem worth its own retry —
                    // not blocked by an earlier retry that already succeeded.
                    self.opusRetriedThisLoad = false
                    // Clears the banner a preceding failed attempt set (e.g.
                    // a retry that then succeeded) — scheduleWithOpusPlayer
                    // itself doesn't clear it the way playCurrent's other
                    // scheduling paths do, since a retry calls it directly.
                    self.errorMessage = nil
                }
            }
        }

        opusFailObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleLoadFailure(
                    message: "AVPlayer playback failed — skipping. \(Self.describeLoadError(err))",
                    userFacingMessage: "Playback error.",
                    retryURL: url
                )
            }
        }

        // Setting `.rate` directly (rather than `.play()`, which always resumes at
        // 1.0×) both starts playback AND applies the user's chosen Speed setting.
        // Activate the session first — the AVPlayer path bypasses the engine (so
        // `startEngineIfNeeded`'s activation), and the session is no longer
        // activated at launch.
        if isPlaying {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.rate = Float(audioSettings.speed)
        }

        updateNowPlaying()
        appLog("Playing via AVPlayer: \(url.lastPathComponent)", category: "audio")
    }

    func tearDownOpusPlayer() {
        opusStatusObserver?.invalidate()
        opusStatusObserver = nil
        if let obs = opusTimeObserver {
            opusPlayer?.removeTimeObserver(obs)
            opusTimeObserver = nil
        }
        // `addObserver(forName:object:queue:using:)` registers an internal proxy as the
        // observer (not `self`), so `removeObserver(self, name:object:)` never matched
        // anything — both block-based observers below were silently leaking on every
        // track switch. Removing by the captured tokens is the only way to unregister them.
        if let obs = opusEndObserver {
            NotificationCenter.default.removeObserver(obs)
            opusEndObserver = nil
        }
        if let obs = opusFailObserver {
            NotificationCenter.default.removeObserver(obs)
            opusFailObserver = nil
        }
        opusPlayer?.pause()
        opusPlayer = nil
    }
}
