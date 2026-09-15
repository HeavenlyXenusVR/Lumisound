import SwiftUI
import AVFoundation

// MARK: - TVPlayContext (queue + where to start)

struct TVPlayContext: Hashable {
    let queue: [TVPlayable]
    let startID: String
}

enum TVRepeatMode {
    case off, all, one

    /// Cycles off → all → one → off, driven by a single button tap.
    var next: TVRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbol: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

// MARK: - TVPlayerModel

@MainActor
final class TVPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var isBuffering = false
    /// True while the full Now Playing screen is on screen.
    ///
    /// The mini-player bar is pinned to the app shell, which the pushed player
    /// sits inside — so without this it would render over the bottom of the
    /// full player, duplicating what that screen already shows and stealing a
    /// focus target from its transport controls.
    @Published var isShowingFullPlayer = false
    @Published var currentIndex = 0
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var queue: [TVPlayable] = []
    @Published private(set) var isShuffled = false
    @Published var repeatMode: TVRepeatMode = .off
    @Published private(set) var sleepTimerEndDate: Date?
    @Published private(set) var lyrics: [TVLyricLine] = []
    @Published private(set) var isLoadingLyrics = false
    @Published var crossfadeEnabled: Bool = UserDefaults.standard.bool(forKey: "tv.player.crossfadeEnabled") {
        didSet { UserDefaults.standard.set(crossfadeEnabled, forKey: "tv.player.crossfadeEnabled") }
    }

    // A real app-wide singleton (not per-screen) — same pattern as
    // `TVAccount.shared`/`TVBridgeClient.shared`, and constructed the same
    // way at the app root (see `TVContentView`'s `@StateObject private var
    // player = TVPlayerModel.shared`). This used to be a plain
    // `@StateObject` owned by `TVPlayerView` itself, torn down (`stop()`
    // on `.onDisappear`) the moment the user navigated away from Now
    // Playing — which meant a Siri/App Intent (TVAppIntents.swift, which
    // runs outside the normal SwiftUI environment the same way a BGTask
    // does on iOS) had nothing reachable to START playback with, only to
    // control an already-open Now Playing screen. Promoting it here is
    // what actually lets Siri start playback from cold, and as a side
    // effect also means playback now keeps going while browsing elsewhere
    // in the app instead of stopping the instant Now Playing closes —
    // matching how the iOS app's `AudioPlayerManager` already behaves.
    static let shared = TVPlayerModel()

    // MARK: Dual-player crossfade
    //
    // Two fixed AVPlayer instances rather than one — crossfading means the
    // outgoing track's player and the incoming track's player must both be
    // audible and advancing at once for `crossfadeDuration` seconds, which a
    // single `replaceCurrentItem` swap can't do. `player` always means
    // "whichever one is currently the audible/active track"; observers (time/
    // status/end) are attached to BOTH once, each self-filtering to only act
    // when it's the currently-active instance — simpler and safer than tearing
    // down and reattaching observers every time the active player changes.
    private let playerA = AVPlayer()
    private let playerB = AVPlayer()
    private var activeIsA = true
    var player: AVPlayer { activeIsA ? playerA : playerB }
    private var inactivePlayer: AVPlayer { activeIsA ? playerB : playerA }
    private let crossfadeDuration: TimeInterval = 6
    private var crossfadeTask: Task<Void, Never>?
    private var hasCrossfadedForCurrentTrack = false

    /// Queue order before shuffling — restored when shuffle is toggled off.
    private var originalQueue: [TVPlayable] = []
    private var endObservers: [NSObjectProtocol] = []
    private var failureObservers: [NSObjectProtocol] = []
    private var timeObservers: [(AVPlayer, Any)] = []
    private var statusObservations: [NSKeyValueObservation] = []
    private var sleepTimerTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    /// The track Aria is handing over FROM — see TVAria.requestTransition.
    private var previousTrack: TVPlayable?
    var audioSessionObservers: [NSObjectProtocol] = []

    var current: TVPlayable? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }

    /// The queue/start-point `start(context:)` most recently actually
    /// adopted — lets repeat calls with the SAME context (e.g. navigating
    /// back to Now Playing without picking a new track, now that this is a
    /// persistent singleton instead of a fresh-per-screen instance) resume
    /// in place rather than restarting, while a genuinely different
    /// context still replaces the queue as before.
    private var currentContext: TVPlayContext?

    func start(context: TVPlayContext) {
        guard currentContext != context else { return }
        currentContext = context
        cancelCrossfade()
        isShuffled = false
        queue = context.queue
        originalQueue = context.queue
        currentIndex = queue.firstIndex(where: { $0.id == context.startID }) ?? 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        setupObservers()
        setupAudioSessionObservers()
        configureRemoteCommands()
        loadCurrent()
    }

    /// Seeks within the current track, clamped to `[0, duration]` — used by
    /// the "skip forward/back N seconds" Siri intents (TVAppIntents.swift).
    /// `position` is updated immediately rather than waiting for the next
    /// periodic time-observer tick, so a seek doesn't visibly lag.
    func seek(to newPosition: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(newPosition, duration))
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func setupObservers() {
        guard endObservers.isEmpty else { return }  // set up once, on both players

        for p in [playerA, playerB] {
            // Only reacts when `p` is the currently-active player AND the item
            // that ended is still that player's current item — guards against
            // a stale notification from a player that's since been reused/
            // reset (e.g. a cancelled crossfade's incoming player).
            let endObs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
            ) { [weak self, weak p] note in
                Task { @MainActor in
                    guard let self, let p, self.player === p,
                          let endedItem = note.object as? AVPlayerItem, endedItem === p.currentItem
                    else { return }
                    self.handleNaturalEnd()
                }
            }
            endObservers.append(endObs)

            // Playback failures (bad stream, dropped connection mid-track)
            // previously went completely unlogged — the UI would just spin
            // forever with nothing surfaced anywhere, client or server.
            let failureObs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
            ) { [weak self, weak p] note in
                Task { @MainActor in
                    guard let self, let p, self.player === p,
                          let failedItem = note.object as? AVPlayerItem, failedItem === p.currentItem
                    else { return }
                    let underlying = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                        ?? p.currentItem?.error?.localizedDescription ?? "unknown error"
                    tvError("Playback failed: \(underlying)", category: "playback",
                            extra: ["title": self.current?.title ?? "?"])
                    TVRemoteLogger.logError(category: "playback", event: "playback_failed", message: underlying)
                }
            }
            failureObservers.append(failureObs)

            // Drives the scrubber + elapsed/remaining time, and the crossfade trigger.
            // 0.2s, not 0.5s: this timer is what advances the lyric
            // highlight, and at 0.5s the lit line lagged the audio by up to
            // half a second, which reads as lyrics simply being out of sync.
            let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
            let timeObs = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak p] time in
                Task { @MainActor in
                    guard let self, let p, self.player === p else { return }
                    self.position = time.seconds.isFinite ? time.seconds : 0
                    if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 {
                        self.duration = d
                    }
                    self.checkCrossfadeTrigger()
                    self.updateNowPlayingInfo()
                }
            }
            timeObservers.append((p, timeObs))

            // Keeps play/pause + the loading spinner in sync with real playback.
            let statusObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self, weak p] observed, _ in
                Task { @MainActor in
                    guard let self, let p, self.player === p else { return }
                    self.isPlaying = observed.timeControlStatus == .playing
                    self.isBuffering = observed.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    self.updateNowPlayingInfo()
                }
            }
            statusObservations.append(statusObs)
        }
    }

    private func asset(for item: TVPlayable) -> AVURLAsset {
        // /api/stream/proxy is check_auth()-gated (needs "Authorization: Bearer
        // <IOS_BRIDGE_API_KEY>") and separately reads the user's personal
        // YouTube key off the raw "X-Account-Token" header; it never reads
        // Authorization for its own business logic, so putting the API key
        // there doesn't collide with anything. /user/music/stream instead
        // checks "Authorization: Bearer <user token>" and ignores
        // X-Account-Token. Both headers are always sent — each endpoint
        // ignores the one it doesn't recognize — except Authorization itself,
        // which has to pick the right value for whichever endpoint this
        // particular item's streamURL actually targets.
        let isStreamProxy = item.streamURL.path == "/api/stream/proxy"
        let authorization = isStreamProxy
            ? "Bearer \(TVBridgeClient.officialBridgeAPIKey)"
            : item.authToken.map { "Bearer \($0)" }
        var headers: [String: String] = [:]
        if let authorization { headers["Authorization"] = authorization }
        if let token = item.authToken { headers["X-Account-Token"] = token }
        guard !headers.isEmpty else { return AVURLAsset(url: item.streamURL) }
        return AVURLAsset(url: item.streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    /// Locked-aware version of `asset(for:)` — a non-locked item resolves
    /// instantly via the same URL/header construction as before. A
    /// Lumisound-locked Personal Cloud Library item (`item.isLocked`) is
    /// downloaded in full and unlocked to a local temp file first, via
    /// `TVLockedTrackCache` — its bytes aren't a decodable audio container
    /// to AVFoundation until that transform is reversed (see
    /// `TVLockFormat`'s header comment). Falls back to the raw (undecoded)
    /// stream on a download/unlock failure, matching this app's "never leave
    /// playback silently stuck" pattern elsewhere — the player's existing
    /// failure observer surfaces that the same way it would any other
    /// unplayable item, rather than hanging forever on a resolution that
    /// already failed.
    private func resolvedAsset(for item: TVPlayable) async -> AVURLAsset {
        guard item.isLocked else { return asset(for: item) }
        if let localURL = await TVLockedTrackCache.shared.playableURL(for: item) {
            return AVURLAsset(url: localURL)
        }
        return asset(for: item)
    }

    private func loadCurrent() {
        guard let item = current else { return }
        cancelCrossfade()
        position = 0
        duration = 0
        isBuffering = true
        player.volume = 1
        loadLyrics(for: item)
        // Single chokepoint for every track transition (initial start, skip,
        // repeat-all wrap, Up Next jump) — logging once here instead of at
        // each caller avoids duplicating this at four call sites.
        tvBreadcrumb("Playing: \(item.title)")
        TVRemoteLogger.log(category: "playback", event: "track_started",
                            detail: ["title": item.title, "artist": item.artist])
        updateNowPlayingInfo()
        updateNowPlayingArtwork()
        // Aria's handover into this track. Fire-and-forget: it never gates
        // playback, so a slow or absent answer costs nothing but a missing line.
        if let token = TVAccount.shared.token {
            TVAria.shared.requestTransition(from: previousTrack, to: item, token: token)
        }
        previousTrack = item

        Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolvedAsset(for: item)
            // The user may have skipped again while a locked track was
            // downloading — don't stomp over whatever's playing now.
            guard self.current?.id == item.id else { return }
            let playerItem = AVPlayerItem(asset: resolved)

            // Stop the system widening stereo music into a virtual surround
            // field. On by default on an Apple TV, and it smears the stereo
            // image — the most likely reason the same file sounds less direct
            // here than on a phone, which never takes this path at all.
            playerItem.allowedAudioSpatializationFormats =
                TVAudioSettings.shared.allowSpatialization ? .monoStereoAndMultichannel : .monoAndStereo

            self.player.replaceCurrentItem(with: playerItem)
            self.player.play()

            // Leading-silence trim, AFTER the item is attached so the seek
            // lands on a real asset. Analysis decodes the head of the file, so
            // it runs off the main actor and only applies if this is still the
            // track playing when it finishes.
            guard TVAudioSettings.shared.skipSilentIntros,
                  let assetURL = (resolved as? AVURLAsset)?.url else { return }
            let trim = await TVSilenceTrim.analyze(url: assetURL, trackID: item.id)
            guard trim > 0, self.current?.id == item.id else { return }
            // `await`: inside an async context Swift resolves seek(to:) to the
            // async overload, which must be awaited rather than fired and
            // forgotten.
            await self.player.seek(to: CMTime(seconds: trim, preferredTimescale: 600))
            TVRemoteLogger.log(category: "audio", event: "silent_intro_skipped",
                               detail: ["title": item.title, "seconds": round(trim * 100) / 100])
        }
    }

    // MARK: Crossfade

    /// Only the natural end of the *active* player's item reaches here — if
    /// a crossfade already claimed this transition (`hasCrossfadedForCurrentTrack`),
    /// `completeCrossfade` handles advancing instead, so this no-ops to avoid
    /// double-advancing.
    private func handleNaturalEnd() {
        guard !hasCrossfadedForCurrentTrack else { return }
        advanceOnEnd()
    }

    private func nextIndexForCrossfade() -> Int? {
        guard crossfadeEnabled, queue.count > 1, repeatMode != .one else { return nil }
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if repeatMode == .all { return 0 }
        return nil
    }

    private func checkCrossfadeTrigger() {
        guard !hasCrossfadedForCurrentTrack, duration > crossfadeDuration,
              duration - position <= crossfadeDuration,
              nextIndexForCrossfade() != nil
        else { return }
        hasCrossfadedForCurrentTrack = true
        beginCrossfade()
    }

    private func beginCrossfade() {
        guard let nextIndex = nextIndexForCrossfade(), queue.indices.contains(nextIndex) else { return }
        let nextItem = queue[nextIndex]
        let outgoing = player
        let incoming = inactivePlayer

        incoming.pause()
        incoming.volume = 0
        tvLog("Crossfade started into: \(nextItem.title)", category: "playback")

        let steps = 30
        let stepNanoseconds = UInt64(crossfadeDuration / Double(steps) * 1_000_000_000)
        crossfadeTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolvedAsset(for: nextItem)
            guard !Task.isCancelled else { return }
            incoming.replaceCurrentItem(with: AVPlayerItem(asset: resolved))
            incoming.play()
            for i in 0...steps {
                guard !Task.isCancelled else { return }
                let t = Double(i) / Double(steps)
                // Equal-power curve so the perceived combined loudness stays
                // roughly constant through the fade, rather than dipping in
                // the middle the way a plain linear crossfade would.
                outgoing.volume = Float(cos(t * .pi / 2))
                incoming.volume = Float(sin(t * .pi / 2))
                try? await Task.sleep(nanoseconds: stepNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self.completeCrossfade(to: nextIndex)
        }
    }

    private func completeCrossfade(to index: Int) {
        logPlayForCurrentTrackIfNeeded()
        let finishedOutgoing = player
        activeIsA.toggle()
        currentIndex = index
        position = 0
        duration = 0
        isBuffering = false
        hasCrossfadedForCurrentTrack = false
        crossfadeTask = nil
        player.volume = 1
        finishedOutgoing.pause()
        finishedOutgoing.replaceCurrentItem(with: nil)
        loadLyrics(for: queue[index])
        let newItem = queue[index]
        tvBreadcrumb("Crossfaded to: \(newItem.title)")
        TVRemoteLogger.log(category: "playback", event: "track_started",
                            detail: ["title": newItem.title, "artist": newItem.artist, "via": "crossfade"])
        updateNowPlayingInfo()
        updateNowPlayingArtwork()
    }

    /// Stops and silences an in-flight crossfade (the not-yet-promoted
    /// incoming player is fully paused/cleared, not just volume-reset —
    /// leaving it playing at any nonzero volume would mean two tracks
    /// audible at once until something else resolved it). Safe to call any
    /// time; a no-op when no crossfade is in flight.
    private func cancelCrossfade() {
        guard crossfadeTask != nil else { return }
        crossfadeTask?.cancel()
        crossfadeTask = nil
        hasCrossfadedForCurrentTrack = false
        player.volume = 1
        inactivePlayer.pause()
        inactivePlayer.replaceCurrentItem(with: nil)
        inactivePlayer.volume = 1
    }

    // MARK: Play history

    /// Reports the currently-loaded track's play to the bridge — called
    /// right before advancing/stopping, while `current`/`position` still
    /// describe the track that's ending. Skips near-instant skips (<2s of
    /// real listening) so scrubbing through a queue doesn't inflate stats;
    /// requires a signed-in token (always true in practice — the player is
    /// only reachable from behind TVAccount's login gate).
    private func logPlayForCurrentTrackIfNeeded() {
        guard let item = current, position > 2, let token = TVAccount.shared.token else { return }
        let listenSeconds = Int(position)
        Task {
            await TVBridgeClient.shared.logPlay(
                title: item.title, artist: item.artist,
                trackURL: item.streamURL.absoluteString,
                listenSeconds: listenSeconds, token: token
            )
        }
    }

    // MARK: Lyrics

    /// Waits briefly for the asset's real duration to load (used to reject a
    /// same-titled-but-wrong recording/song — see TVLyricsService) before
    /// fetching, falling back to an undisambiguated search if it takes too
    /// long. Re-checks `current?.id == item.id` after every suspension point
    /// since the user may have skipped tracks while this was waiting/in flight.
    private func loadLyrics(for item: TVPlayable) {
        lyricsTask?.cancel()
        lyrics = []
        isLoadingLyrics = true
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            // Cleared on EVERY exit. It was only cleared on the success path, so
            // any of the three early returns below — the user skipping tracks
            // while the duration probe waited, or while the fetch was in flight,
            // or the task being cancelled outright — left the flag stuck true
            // for the rest of the session. The UI then showed "loading lyrics"
            // forever for a track whose fetch had long since been abandoned,
            // which is indistinguishable from a hung request.
            defer { self.isLoadingLyrics = false }

            var waited = 0.0
            while self.duration <= 0, waited < 5, !Task.isCancelled, self.current?.id == item.id {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            guard !Task.isCancelled, self.current?.id == item.id else { return }
            let started = Date()
            let fetched = await TVLyricsService.fetch(title: item.title, artist: item.artist, duration: self.duration)
            guard !Task.isCancelled, self.current?.id == item.id else { return }
            self.lyrics = fetched ?? []

            // Whether a lookup MATCHED is the only way to tell "this track has
            // no lyrics published" from "our query never had a chance" — a
            // title like "How It's Done (from the Netflix film KPop Demon
            // Hunters)" carries a parenthetical the lyrics database does not
            // have. Logging the title we actually searched with, and the
            // outcome, is what makes that difference measurable instead of a
            // guess about why the panel is empty.
            TVRemoteLogger.log(
                category: "lyrics",
                event: fetched?.isEmpty == false ? "lyrics_matched" : "lyrics_not_found",
                detail: [
                    "title": item.title,
                    "artist": item.artist,
                    "hasParenthetical": item.title.contains("("),
                    "titleLength": item.title.count,
                    "durationKnown": self.duration > 0,
                    "lineCount": fetched?.count ?? 0,
                    "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
                ]
            )
        }
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    /// Manual "skip forward" — always advances (or stops at the end of a
    /// non-repeating queue), regardless of repeat mode. Repeat-one only
    /// affects what happens when a track ends on its own; see `advanceOnEnd`.
    func next() {
        cancelCrossfade()
        guard currentIndex + 1 < queue.count else {
            if repeatMode == .all, !queue.isEmpty {
                logPlayForCurrentTrackIfNeeded()
                currentIndex = 0
                loadCurrent()
            } else {
                logPlayForCurrentTrackIfNeeded()
                player.pause()
            }
            return
        }
        logPlayForCurrentTrackIfNeeded()
        currentIndex += 1
        loadCurrent()
    }

    /// Called when the current item finishes playing on its own.
    private func advanceOnEnd() {
        if repeatMode == .one {
            logPlayForCurrentTrackIfNeeded()
            player.seek(to: .zero)
            player.play()
            return
        }
        next()
    }

    /// Jumps directly to a track elsewhere in the queue — used by the "Up
    /// Next" panel so picking a track doesn't require stepping through
    /// `next()` one at a time.
    func jump(to index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        cancelCrossfade()
        logPlayForCurrentTrackIfNeeded()
        currentIndex = index
        loadCurrent()
    }

    func previous() {
        cancelCrossfade()
        // If we're more than 3s in, restart the track instead of skipping back.
        if position > 3 {
            player.seek(to: .zero); return
        }
        guard currentIndex > 0 else { player.seek(to: .zero); return }
        logPlayForCurrentTrackIfNeeded()
        currentIndex -= 1
        loadCurrent()
    }

    /// Removes a queued-up track. The currently-playing track can't be
    /// removed this way — skip to another track first.
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        // A removal could invalidate the index an in-flight crossfade is
        // ramping toward — simplest safe response is to cancel it; the
        // transition falls back to an instant swap when this track ends.
        cancelCrossfade()
        let removedID = queue[index].id
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        originalQueue.removeAll { $0.id == removedID }
    }

    /// Shuffles everything except leaves the currently-playing track findable
    /// by id afterward (rather than resetting to index 0), so toggling
    /// shuffle mid-playback doesn't yank the listener to a different track.
    func toggleShuffle() {
        isShuffled.toggle()
        let currentID = current?.id
        queue = isShuffled ? originalQueue.shuffled() : originalQueue
        if let currentID {
            currentIndex = queue.firstIndex(where: { $0.id == currentID }) ?? 0
        }
        TVRemoteLogger.log(category: "playback", event: "shuffle_toggled", detail: ["enabled": isShuffled])
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
        TVRemoteLogger.log(category: "playback", event: "repeat_mode_changed", detail: ["mode": "\(repeatMode)"])
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEndDate = end
        tvLog("Sleep timer set for \(minutes) minutes", category: "playback")
        TVRemoteLogger.log(category: "playback", event: "sleep_timer_set", detail: ["minutes": minutes])
        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = end.timeIntervalSinceNow
                if remaining <= 0 {
                    self.player.pause()
                    self.sleepTimerEndDate = nil
                    tvBreadcrumb("Sleep timer paused playback")
                    TVRemoteLogger.log(category: "playback", event: "sleep_timer_fired")
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func cancelSleepTimer() {
        // `sleepTimerEndDate` (not `sleepTimerTask`) is the accurate "is a
        // timer genuinely pending" check — the task reference itself stays
        // non-nil even after firing naturally, which would otherwise log a
        // misleading "cancelled" event for a timer that already fired.
        guard sleepTimerEndDate != nil else { return }
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
        TVRemoteLogger.log(category: "playback", event: "sleep_timer_cancelled")
    }

    func stop() {
        logPlayForCurrentTrackIfNeeded()
        crossfadeTask?.cancel()
        crossfadeTask = nil
        for p in [playerA, playerB] {
            p.pause()
            p.replaceCurrentItem(with: nil)
        }
        for (p, observer) in timeObservers { p.removeTimeObserver(observer) }
        timeObservers.removeAll()
        statusObservations.forEach { $0.invalidate() }
        statusObservations.removeAll()
        endObservers.forEach { NotificationCenter.default.removeObserver($0) }
        endObservers.removeAll()
        failureObservers.forEach { NotificationCenter.default.removeObserver($0) }
        failureObservers.removeAll()
        cancelSleepTimer()
        lyricsTask?.cancel()
        lyricsTask = nil
        teardownAudioSessionObservers()
        teardownRemoteCommands()
    }
}

// MARK: - TVPlayerView

private enum TVSidePanel: Equatable { case none, upNext, lyrics }

struct TVPlayerView: View {
    /// The queue to START when this screen appears — nil when Now Playing is
    /// opened from the mini-player bar rather than by picking a track.
    ///
    /// Previously required, which meant the full player was reachable ONLY as
    /// a NavigationLink destination from a list: once you navigated away there
    /// was no route back to what was playing. `TVPlayerModel.shared` already
    /// holds the live queue and current track, so with no context this screen
    /// simply renders that instead of starting anything.
    var context: TVPlayContext? = nil
    @ObservedObject var client: TVBridgeClient
    let token: String
    // `@StateObject` still (not `@ObservedObject`) even though the instance
    // now comes from `.shared` rather than being constructed here — SwiftUI
    // needs `@StateObject` semantics (never re-created across this view's
    // own re-renders) for its lifecycle management, and `init(_:)` taking
    // an already-live instance is exactly `@StateObject`'s documented way
    // to adopt an externally-owned object, same as `TVContentView`'s own
    // `@StateObject private var client = TVBridgeClient.shared`.
    @StateObject private var model = TVPlayerModel.shared
    @State private var sidePanel: TVSidePanel = .none
    // tvOS never automatically moves focus into a view that appears over
    // already-focused content — `upNextPanel` is drawn in the same ZStack
    // as the transport controls, not a real `.sheet`, so without this the
    // panel shows up but the Siri Remote's focus silently stays on
    // whatever utility button opened it. Forced onto the panel's close
    // button in `.onChange(of: sidePanel)` below the instant it opens.
    // (TVLyricsPanel does the same thing internally for itself.)
    @FocusState private var upNextCloseFocused: Bool
    @State private var showSleepTimerSheet = false
    @State private var showArtworkStyleSheet = false
    @AppStorage("tv.nowPlaying.artworkStyle") private var artworkStyleRaw = TVArtworkStyle.classic.rawValue
    /// Drives the ambient glow's "breathing" pulse behind the artwork —
    /// toggled once on appear rather than animating a constant, since a
    /// `repeatForever` animation needs an actual value change to attach to.
    @State private var breathe = false
    /// Drives default focus onto play/pause when this screen appears.
    @FocusState private var playPauseFocused: Bool

    private var artworkStyle: TVArtworkStyle { TVArtworkStyle(rawValue: artworkStyleRaw) ?? .classic }

    private var displayed: TVPlayable? {
        model.current ?? context.flatMap { ctx in ctx.queue.first(where: { $0.id == ctx.startID }) }
    }

    var body: some View {
        ZStack {
            backdrop

            // One glass slab holding the track, with the transport floating
            // beneath it. The previous layout put artwork and a text column
            // side by side directly on the backdrop, so the screen had no
            // figure — just elements scattered over a blurred photo, and the
            // transport was buried in the middle of the text column where it
            // competed with the title for the same vertical space.
            // Centred as a group rather than pinned to the top, now that the
            // slab is only as tall as its content.
            VStack(spacing: 28) {
                mainSlab
                transportBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, TVMetrics.margin)
            .padding(.vertical, 40)
            .focusSection()

            if sidePanel == .upNext {
                upNextPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if sidePanel == .lyrics {
                TVLyricsPanel(
                    lines: model.lyrics,
                    currentPosition: model.position,
                    isPlaying: model.isPlaying,
                    isLoading: model.isLoadingLyrics,
                    onClose: { withAnimation(.easeInOut(duration: 0.25)) { sidePanel = .none } }
                )
                .transition(.opacity)
            }
        }
        .onDisappear { model.isShowingFullPlayer = false }
        .onAppear {
            // No context = opened from the now-playing column; whatever is
            // already playing stays playing.
            if let context { model.start(context: context) }
            model.isShowingFullPlayer = true
            breathe = true
            // tvOS doesn't move focus into a newly pushed screen on its own, so
            // without this the remote's first press lands on whatever the focus
            // engine happens to pick — usually a utility button rather than
            // play/pause. Managing default focus explicitly is the documented
            // expectation for tvOS screens with a clear primary action.
            playPauseFocused = true
        }
        .onChange(of: sidePanel) { newValue in
            // Forces focus into the panel the instant it opens — see
            // `upNextCloseFocused`'s doc comment. TVLyricsPanel does the
            // same thing for itself internally via its own `.onAppear`,
            // since it owns its own close button/FocusState.
            guard newValue == .upNext else { return }
            upNextCloseFocused = true
        }
        // No `.onDisappear { model.stop() }` — `model` is the app-wide
        // `TVPlayerModel.shared`, not an instance scoped to this screen, so
        // navigating away from Now Playing leaves playback running (matching
        // the iOS app's `AudioPlayerManager`) rather than killing it.
    }

    // MARK: Slab

    /// Artwork, track, and lyrics in a single translucent panel.
    private var mainSlab: some View {
        HStack(alignment: .top, spacing: 52) {
            VStack(spacing: 26) {
                artwork
                artworkStyleMenu
            }

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    // The favourite control is NOT here any more. Sitting on
                    // the title's baseline it was the only focusable thing in
                    // the upper half of the panel, separated from every other
                    // control by an unfocusable progress bar — so reaching it
                    // meant guessing that "up" from the utility row led
                    // somewhere. It lives in the utility row now, with the rest
                    // of the controls, which is where someone looks for it.
                    Text(displayed?.title ?? "")
                        .font(TVType.display)
                        .lineLimit(3)
                        .minimumScaleFactor(0.55)
                        .id(displayed?.id)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    Text((displayed?.artist.isEmpty ?? true) ? "Unknown Artist" : (displayed?.artist ?? ""))
                        .font(TVType.hero)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .id(displayed?.id)
                        .transition(.opacity)
                }
                .animation(.easeOut(duration: 0.4), value: displayed?.id)

                progressBar

                utilityRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Lyrics are shown here rather than only behind a toggle. They are
            // the one thing on this screen that changes second to second, and a
            // full-screen player that cannot show them without covering itself
            // is the reason the overlay panel existed at all. The overlay stays
            // for reading a whole song; this is for following one.
            // Always present, so the column keeps a stable width and the
            // absence of lyrics is STATED rather than shown as a blank half of
            // the panel. An empty area is ambiguous — still loading, none
            // published, or broken all look identical.
            inlineLyrics
                .frame(width: 400)
        }
        .padding(46)
        // Hugs its content vertically. It was `maxHeight: .infinity` with
        // top-aligned content, which stretched the panel to the full window and
        // left most of it empty — a large slab of blank colour under the
        // artwork, with the transport pushed off the bottom edge. A panel should
        // be the size of what it holds; the empty space belongs to the backdrop.
        .frame(maxWidth: 1440, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .fill(TVPalette.ground.opacity(0.32))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.32), TVPalette.neon.opacity(0.22), .white.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                }
                .shadow(color: .black.opacity(0.55), radius: 44, y: 22)
        }
    }

    /// Five lines centred on the current one, the active line lit. Non-focusable
    /// on purpose: it is a readout, and making it focusable would put a stop on
    /// the path between the artwork and the utility row for no action gained.
    @ViewBuilder
    private var inlineLyrics: some View {
        let idx = currentLyricIndex
        VStack(alignment: .leading, spacing: 14) {
            Text("LYRICS")
                .font(TVType.eyebrow)
                .tracking(2.2)
                .foregroundStyle(.secondary)

            if model.isLoadingLyrics {
                HStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Looking for lyrics…")
                        .font(TVType.rowDetail)
                        .foregroundStyle(.white.opacity(0.45))
                }
            } else if model.lyrics.isEmpty {
                Text("No synced lyrics for this track.")
                    .font(TVType.rowDetail)
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(2)
            } else {
                ForEach(visibleLyricRange(around: idx), id: \.self) { i in
                    Text(model.lyrics[i].text)
                        .font(.system(size: i == idx ? 27 : 22,
                                      weight: i == idx ? .semibold : .regular))
                        .foregroundStyle(i == idx ? Color.white : Color.white.opacity(0.34))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // A FIXED height, clipped.
        //
        // Two problems this solves. The block's height varied with how many
        // lines the current window happened to wrap to, so the panel resized
        // itself as the song played. And because the window is a `ForEach` over
        // changing indices, lines are inserted and removed as the song advances
        // — SwiftUI animates those in and out, and with nothing clipping the
        // container they were drawn outside it mid-transition, which is the
        // text appearing over the edge of the box.
        //
        // Still not `maxHeight: .infinity`: a child asking for infinity
        // overrides a parent that wanted to hug its content, which is what kept
        // the whole panel stretched to the window earlier.
        .frame(height: 210, alignment: .top)
        .clipped()
        .animation(.easeOut(duration: 0.28), value: idx)
    }

    /// Index of the last lyric line whose timestamp has passed, or -1 before the
    /// first. Linear scan: a few hundred lines at most, once per render.
    private var currentLyricIndex: Int {
        var result = -1
        for (i, line) in model.lyrics.enumerated() {
            if line.time <= model.position { result = i } else { break }
        }
        return result
    }

    private func visibleLyricRange(around index: Int) -> [Int] {
        let count = model.lyrics.count
        guard count > 0 else { return [] }
        let window = min(5, count)
        let centre = max(0, index)
        let start = max(0, min(centre - 2, count - window))
        return Array(start..<(start + window))
    }

    // MARK: Transport

    /// The transport as a floating capsule under the slab, rather than a row
    /// inside the text column. It is the screen's primary control, so it gets
    /// its own surface and the full width to centre in, and moving it out of the
    /// column stops it fighting the title for vertical space.
    private var transportBar: some View {
        HStack(spacing: 34) {
            // Seeking, as explicit jump buttons rather than a scrubbable bar.
            //
            // A scrub bar on tvOS has to claim left/right while focused, and a
            // view that consumes directional input is a view focus can get
            // stuck inside — the failure mode that made an earlier build
            // unusable. Jump buttons need no focus interception at all, are
            // unambiguous from a sofa, and are what the platform's own music
            // playback UI offers. A press-to-scrub bar can follow once it can be
            // tested on a real device.
            controlButton("gobackward.15") { model.seek(to: model.position - 15) }
            controlButton("backward.fill") { model.previous() }
            controlButton(model.isPlaying ? "pause.fill" : "play.fill", big: true) {
                model.togglePlayPause()
            }
            .focused($playPauseFocused)
            controlButton("forward.fill") { model.next() }
            controlButton("goforward.15") { model.seek(to: model.position + 15) }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 18)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay { Capsule().fill(TVPalette.ground.opacity(0.35)) }
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.30), TVPalette.neon.opacity(0.25)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5
                    )
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
        }
    }

    private func togglePanel(_ panel: TVSidePanel) {
        withAnimation(.easeInOut(duration: 0.25)) {
            sidePanel = sidePanel == panel ? .none : panel
        }
    }

    // MARK: Utility row (shuffle / repeat / sleep timer / lyrics / artwork style / up next)

    private var utilityRow: some View {
        HStack(spacing: 26) {
            if let songID = displayed?.favoriteSongID {
                favoriteButton(songID: songID)
            }
            toggleIconButton("shuffle", isOn: model.isShuffled) { model.toggleShuffle() }
            toggleIconButton(model.repeatMode.symbol, isOn: model.repeatMode != .off) { model.cycleRepeatMode() }
            toggleIconButton("arrow.triangle.merge", isOn: model.crossfadeEnabled) {
                model.crossfadeEnabled.toggle()
                TVRemoteLogger.log(category: "playback", event: "crossfade_toggled",
                                    detail: ["enabled": model.crossfadeEnabled])
            }
            sleepTimerMenu
            toggleIconButton("quote.bubble", isOn: sidePanel == .lyrics) { togglePanel(.lyrics) }
            // artworkStyleMenu is NOT here any more: it moved under the artwork,
            // beside the thing it actually changes. Leaving it in both places put
            // the same control on screen twice.
            if model.queue.count > 1 {
                Text("\(model.currentIndex + 1) of \(model.queue.count)")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                Button {
                    togglePanel(.upNext)
                } label: {
                    Label("Up Next", systemImage: "list.bullet")
                }
            }
        }
    }

    private func toggleIconButton(_ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TVUtilityButtonLabel(symbol: symbol, isOn: isOn)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func favoriteButton(songID: String) -> some View {
        Button {
            Task {
                guard let track = client.library.first(where: { $0.id == songID }) else { return }
                await client.toggleFavorite(track: track, token: token)
            }
        } label: {
            TVUtilityButtonLabel(symbol: client.isFavorite(songID) ? "star.fill" : "star",
                                  isOn: client.isFavorite(songID), tint: .yellow)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var sleepTimerMenu: some View {
        Button {
            showSleepTimerSheet = true
        } label: {
            TVUtilityButtonLabel(symbol: model.sleepTimerEndDate != nil ? "moon.fill" : "moon",
                                  isOn: model.sleepTimerEndDate != nil)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .sheet(isPresented: $showSleepTimerSheet) {
            TVSleepTimerSheet(hasActiveTimer: model.sleepTimerEndDate != nil) { minutes in
                if let minutes {
                    model.setSleepTimer(minutes: minutes)
                } else {
                    model.cancelSleepTimer()
                }
            }
        }
    }

    private var artworkStyleMenu: some View {
        Button {
            showArtworkStyleSheet = true
        } label: {
            TVUtilityButtonLabel(symbol: "paintpalette", isOn: artworkStyle != .classic)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .sheet(isPresented: $showArtworkStyleSheet) {
            TVArtworkStyleSheet(current: artworkStyle) { style in
                artworkStyleRaw = style.rawValue
                TVRemoteLogger.log(category: "playback", event: "artwork_style_changed",
                                    detail: ["style": style.rawValue])
            }
        }
    }

    // MARK: Up Next panel
    //
    // Slides over the artwork/transport rather than using `.sheet` — tvOS's
    // focus engine handles an in-place overlay more predictably than a modal
    // here, and it keeps the now-playing transport reachable underneath.

    /// Up Next, rebuilt to match the rest of the port.
    ///
    /// What it was: a flat black 85%-opaque slab, plain-system rows of a generic
    /// music-note glyph and two lines of text, and a SECOND focusable remove
    /// button on every row — so getting from the top of the queue to the bottom
    /// took two presses per track, and every row used `.buttonStyle(.card)`, the
    /// system lift sized for square artwork, which on a full-width row makes the
    /// whole panel appear to jump.
    ///
    /// What it is now: artwork per row so the queue is scannable by cover rather
    /// than by reading every title, the playing row called out with the app's own
    /// accent instead of a grey glyph, one focusable element per row, and the
    /// panel itself on the same glass-over-indigo as everything else.
    ///
    /// Removing a track moved into the row's long-press context menu. A queue is
    /// something you move THROUGH far more often than you edit, so the common
    /// action gets the press and the rare one gets the menu — the same tradeoff
    /// the library rows already make for favouriting.
    private var upNextPanel: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Up Next").font(TVType.section)
                        Text("\(model.queue.count - model.currentIndex - 1) after this")
                            .font(TVType.rowDetail)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { sidePanel = .none }
                    } label: {
                        TVUtilityButtonLabel(symbol: "xmark", isOn: false)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .focused($upNextCloseFocused)
                }
                .padding(.horizontal, 36)
                .padding(.top, 46)
                .padding(.bottom, 26)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TVMetrics.row) {
                        ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                            Button {
                                model.jump(to: index)
                            } label: {
                                TVUpNextRow(
                                    item: item,
                                    position: index + 1,
                                    isCurrent: index == model.currentIndex,
                                    isPlayed: index < model.currentIndex,
                                    isPlaying: model.isPlaying
                                )
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .contextMenu {
                                if index != model.currentIndex {
                                    Button(role: .destructive) {
                                        model.removeFromQueue(at: index)
                                    } label: {
                                        Label("Remove from Queue", systemImage: "minus.circle")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 44)
                }
            }
            .frame(width: 660, alignment: .top)
            .frame(maxHeight: .infinity)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(TVPalette.ground.opacity(0.55))
                }
                .overlay(alignment: .leading) {
                    LinearGradient(colors: [TVPalette.neon.opacity(0.6), TVPalette.neonAlt.opacity(0.35)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: 1.5)
                }
            }
        }
        .ignoresSafeArea()
        .focusSection()
    }

    /// Matches `TVAmbientBackground`'s treatment so pushing into the player is a
    /// continuation of the shell rather than a jump to a differently-coloured
    /// screen: the same artwork, the same indigo wash, just less dimmed, since
    /// here the artwork IS the subject rather than a backdrop behind a list.
    @ViewBuilder private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [TVPalette.surface, TVPalette.ground],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            TVAuthImage(url: displayed?.artworkURL, token: displayed?.authToken) { Color.clear }
                .scaleEffect(1.4)
                .blur(radius: 100)
                .saturation(1.3)
                .overlay(TVPalette.ground.opacity(0.55))
            LinearGradient(colors: [.clear, TVPalette.ground.opacity(0.7)],
                           startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    /// Soft, slowly "breathing" halo behind the artwork, using the same
    /// image as the full-screen backdrop rather than a flat accent color —
    /// it reads as light cast off the artwork itself instead of a generic
    /// decorative glow, and it's most alive right when a track is actually
    /// playing (dims and stops pulsing on pause, a quiet way of reinforcing
    /// play state beyond just the button icon).
    @ViewBuilder private var artworkGlow: some View {
        TVAuthImage(url: displayed?.artworkURL, token: displayed?.authToken) { Color.clear }
            .blur(radius: 70)
            .saturation(1.4)
            .opacity(model.isPlaying ? 0.85 : 0.35)
            .scaleEffect(breathe ? 1.08 : 0.92)
            .animation(
                .easeInOut(duration: 3.2).repeatForever(autoreverses: true),
                value: breathe
            )
            .animation(.easeInOut(duration: 0.6), value: model.isPlaying)
    }

    @ViewBuilder private var artwork: some View {
        ZStack {
            artworkGlow
                .frame(width: 440, height: 440)

            switch artworkStyle {
            case .classic:
                classicArtwork
            case .circuitPulse:
                TVCircuitPulseArtworkView(artworkURL: displayed?.artworkURL, authToken: displayed?.authToken, isPlaying: model.isPlaying)
            case .radarSweep:
                TVRadarSweepArtworkView(artworkURL: displayed?.artworkURL, authToken: displayed?.authToken, isPlaying: model.isPlaying)
            }

            if model.isBuffering {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 14) {
                        ProgressView().scaleEffect(1.6).tint(.white)
                        Text("Loading…").font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                    }
                }
                .frame(width: 440, height: 440)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .frame(width: 440, height: 440)
    }

    private var classicArtwork: some View {
        TVAuthImage(url: displayed?.artworkURL, token: displayed?.authToken) {
            ZStack {
                Color.gray.opacity(0.3)
                Image(systemName: "music.note").font(.system(size: 90)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 440, height: 440)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
    }

    private var progressBar: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(
                            LinearGradient(colors: [Color.accentColor, .white],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * fraction)
                    // Playhead — a small glowing dot at the current position,
                    // pulsing gently while playing so the bar doesn't read as
                    // a static, dead-looking track marker.
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: Color.accentColor.opacity(model.isPlaying ? 0.9 : 0), radius: 8)
                        .scaleEffect(breathe && model.isPlaying ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathe)
                        .offset(x: geo.size.width * fraction - 8)
                }
            }
            .frame(height: 8)
            HStack {
                Text(timeString(model.position))
                Spacer()
                Text(model.duration > 0 ? "-" + timeString(max(0, model.duration - model.position)) : "")
            }
            .font(.system(size: 22, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var fraction: Double {
        model.duration > 0 ? min(1, max(0, model.position / model.duration)) : 0
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private func controlButton(_ symbol: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TVTransportButtonLabel(symbol: symbol, big: big)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Focus-reactive label for the main transport buttons (play/pause, skip).
/// A plain `Button` on tvOS gets the system's default focus treatment, which
/// reads as fairly flat for a full-screen Now Playing surface — this scales
/// up, lifts with a soft accent-colored glow, and fills in behind the glyph
/// when the Siri Remote's focus lands on it, so the transport row feels like
/// a deliberately designed control cluster rather than plain SF Symbols.
private struct TVTransportButtonLabel: View {
    let symbol: String
    let big: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let size: CGFloat = big ? 122 : 92
        ZStack {
            Circle()
                .fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.05))
            Image(systemName: symbol)
                .font(.system(size: big ? 44 : 30, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .scaleEffect(isFocused ? 1.16 : 1.0)
        .shadow(color: isFocused ? Color.accentColor.opacity(0.6) : .clear, radius: isFocused ? 20 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
    }
}

/// Same focus treatment as `TVTransportButtonLabel`, sized down for the
/// utility row (shuffle/repeat/crossfade/sleep timer/lyrics/artwork style)
/// and the inline favorite star — a smaller glow/scale so a row of six of
/// these doesn't compete with the transport buttons for visual weight.
private struct TVUtilityButtonLabel: View {
    let symbol: String
    var isOn: Bool = false
    var tint: Color = .accentColor
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack {
            Circle()
                .fill(isFocused ? Color.white.opacity(0.16) : Color.clear)
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isOn ? tint : (isFocused ? Color.white : Color.secondary))
        }
        .frame(width: 64, height: 64)
        .scaleEffect(isFocused ? 1.14 : 1.0)
        .shadow(color: isFocused ? tint.opacity(0.5) : .clear, radius: isFocused ? 12 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isFocused)
    }
}

// MARK: - Sleep timer / artwork style pickers
//
// `Menu` needs tvOS 17 — this project's deployment target is tvOS 16 (see
// project.yml) — so these use the same `.sheet` + `List` picker pattern
// already proven elsewhere (TVAddToPlaylistSheet, TVPlaylistNameSheet)
// instead.

private struct TVSleepTimerSheet: View {
    let hasActiveTimer: Bool
    /// `nil` selection means "cancel the active timer".
    let onSelect: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if hasActiveTimer {
                    Button(role: .destructive) {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        Label("Cancel Sleep Timer", systemImage: "moon.slash")
                    }
                }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") {
                        onSelect(minutes)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }
}

private struct TVArtworkStyleSheet: View {
    let current: TVArtworkStyle
    let onSelect: (TVArtworkStyle) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(TVArtworkStyle.allCases) { style in
                    Button {
                        onSelect(style)
                        dismiss()
                    } label: {
                        HStack {
                            Text(style.displayName)
                            if style == current {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Artwork Style")
        }
    }
}
