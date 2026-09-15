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
            let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
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
        Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolvedAsset(for: item)
            // The user may have skipped again while a locked track was
            // downloading — don't stomp over whatever's playing now.
            guard self.current?.id == item.id else { return }
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: resolved))
            self.player.play()
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
            var waited = 0.0
            while self.duration <= 0, waited < 5, !Task.isCancelled, self.current?.id == item.id {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            guard !Task.isCancelled, self.current?.id == item.id else { return }
            let fetched = await TVLyricsService.fetch(title: item.title, artist: item.artist, duration: self.duration)
            guard !Task.isCancelled, self.current?.id == item.id else { return }
            self.lyrics = fetched ?? []
            self.isLoadingLyrics = false
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
            HStack(spacing: 70) {
                artwork
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(displayed?.title ?? "")
                                .font(.system(size: 46, weight: .bold))
                                .lineLimit(2)
                                .id(displayed?.id)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                            if let songID = displayed?.favoriteSongID {
                                favoriteButton(songID: songID)
                            }
                        }
                        Text((displayed?.artist.isEmpty ?? true) ? "Unknown Artist" : (displayed?.artist ?? ""))
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .id(displayed?.id)
                            .transition(.opacity)
                    }
                    .animation(.easeOut(duration: 0.4), value: displayed?.id)
                    progressBar
                    HStack(spacing: 44) {
                        controlButton("backward.fill") { model.previous() }
                        controlButton(model.isPlaying ? "pause.fill" : "play.fill", big: true) { model.togglePlayPause() }
                            .focused($playPauseFocused)
                        controlButton("forward.fill") { model.next() }
                    }
                    utilityRow
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            .padding(.horizontal, 110)
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
            // No context = opened from the mini-player; whatever is already
            // playing stays playing.
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
        // No `.onDisappear { model.stop() }` anymore — `model` is the app-
        // wide `TVPlayerModel.shared` now, not a fresh instance scoped to
        // this screen, so navigating away from Now Playing should leave
        // playback running (matches the iOS app's `AudioPlayerManager`)
        // rather than killing it. `stop()` is still exactly what a real
        // user-initiated "stop" action should call — there just isn't one
        // wired up in this UI today (browsing away only pauses/keeps
        // playing, never force-stops), same as before this change for
        // every OTHER way of leaving Now Playing that already existed.
    }

    private func togglePanel(_ panel: TVSidePanel) {
        withAnimation(.easeInOut(duration: 0.25)) {
            sidePanel = sidePanel == panel ? .none : panel
        }
    }

    // MARK: Utility row (shuffle / repeat / sleep timer / lyrics / artwork style / up next)

    private var utilityRow: some View {
        HStack(spacing: 30) {
            toggleIconButton("shuffle", isOn: model.isShuffled) { model.toggleShuffle() }
            toggleIconButton(model.repeatMode.symbol, isOn: model.repeatMode != .off) { model.cycleRepeatMode() }
            toggleIconButton("arrow.triangle.merge", isOn: model.crossfadeEnabled) {
                model.crossfadeEnabled.toggle()
                TVRemoteLogger.log(category: "playback", event: "crossfade_toggled",
                                    detail: ["enabled": model.crossfadeEnabled])
            }
            sleepTimerMenu
            toggleIconButton("quote.bubble", isOn: sidePanel == .lyrics) { togglePanel(.lyrics) }
            artworkStyleMenu
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
    }

    private var sleepTimerMenu: some View {
        Button {
            showSleepTimerSheet = true
        } label: {
            TVUtilityButtonLabel(symbol: model.sleepTimerEndDate != nil ? "moon.fill" : "moon",
                                  isOn: model.sleepTimerEndDate != nil)
        }
        .buttonStyle(.plain)
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

    private var upNextPanel: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Up Next")
                        .font(.system(size: 30, weight: .bold))
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { sidePanel = .none }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .focused($upNextCloseFocused)
                }
                .padding(.horizontal, 40)
                .padding(.top, 50)
                .padding(.bottom, 20)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 20) {
                                Button {
                                    model.jump(to: index)
                                } label: {
                                    HStack(spacing: 20) {
                                        Image(systemName: index == model.currentIndex ? "speaker.wave.2.fill" : "music.note")
                                            .foregroundStyle(index == model.currentIndex ? Color.accentColor : Color.secondary)
                                            .frame(width: 30)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title).font(.title3).lineLimit(1)
                                            Text(item.artist.isEmpty ? "Unknown Artist" : item.artist)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.leading, 40)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.card)

                                if index != model.currentIndex {
                                    Button {
                                        model.removeFromQueue(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.card)
                                    .padding(.trailing, 40)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .frame(width: 620, alignment: .top)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.85))
        }
        .ignoresSafeArea()
        .focusSection()
    }

    @ViewBuilder private var backdrop: some View {
        ZStack {
            Color.black
            TVAuthImage(url: displayed?.artworkURL, token: displayed?.authToken) { Color.black }
                .blur(radius: 90)
                .opacity(0.55)
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
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
        .frame(width: 720)
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
