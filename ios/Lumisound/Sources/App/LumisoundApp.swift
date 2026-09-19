import SwiftUI
import UIKit

@main
struct LumisoundApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var libraryManager = LibraryManager()
    @StateObject private var player = AudioPlayerManager()
    @StateObject private var sleepTimer = SleepTimerService()
    @StateObject private var updater = UpdateService.shared
    @StateObject private var streaming = StreamingService()
    @StateObject private var folderService = MusicFolderService()
    @StateObject private var bgService = BackgroundService()
    @StateObject private var account = AccountService()
    @StateObject private var bridgeHealth = BridgeHealthService()
    @StateObject private var moodService = MoodPlaylistService()
    @StateObject private var cacheManager = CacheManagerService()
    @StateObject private var sharePlay = SharePlayCoordinator()
    @StateObject private var appLock = AppLockService()
    @StateObject private var recentlyDeleted = RecentlyDeletedService()
    @StateObject private var aiDJ = AIDJService()
    @StateObject private var silenceTrim = SilenceTrimService()
    @StateObject private var discordVerification = DiscordVerificationService.shared
    /// Shared app-wide instance so the Profile/Friends tabs, the Library
    /// hub's friends-activity carousel, and Account settings all see the
    /// same friends list / profile / incoming-requests state instead of
    /// each maintaining its own independent copy (which is what happened
    /// when `AccountView` and `LibraryHubView` each constructed their own
    /// `SocialService()` — fine when only one of those screens existed at
    /// a time, but no longer once Profile/Friends became their own tabs
    /// living alongside the Library hub).
    @StateObject private var social = SocialService()

    @State private var showLaunch = true
    @Environment(\.scenePhase) private var scenePhase
    /// Security hardening — the iOS App Switcher shows a live screenshot of
    /// whatever's on screen the instant an app resigns active, independent
    /// of (and earlier than) App Lock's own re-entry gate below: App Lock
    /// only re-authenticates on RETURN, so without this, a screen showing
    /// something sensitive (the Discord Rich Presence setup token, an API
    /// key field, a payment-adjacent screen) would still be captured
    /// plainly in that thumbnail even with App Lock fully enabled. This
    /// blur applies unconditionally, on every backgrounding, regardless of
    /// the App Lock setting — a privacy measure, not an authentication one.
    /// Keyed on `.inactive` (not `.background`) since that's the earlier of
    /// the two transitions and closer to when the OS actually takes the
    /// snapshot.
    @State private var isSnapshotBlurred = false

    init() {
        // Must happen before the app finishes launching — too late if done
        // from a View's .task/.onAppear. See BackgroundRefreshService's docs
        // for what this actually does (and doesn't) guarantee.
        BackgroundRefreshService.register()
        LumisoundTrackVaultService.register()
        PerformanceMonitorService.start()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(libraryManager)
                    .environmentObject(player)
                    .environmentObject(player.progress)
                    .environmentObject(sleepTimer)
                    .environmentObject(updater)
                    .environmentObject(streaming)
                    .environmentObject(folderService)
                    .environmentObject(bgService)
                    .environmentObject(account)
                    .environmentObject(bridgeHealth)
                    .environmentObject(moodService)
                    .environmentObject(cacheManager)
                    .environmentObject(sharePlay)
                    .environmentObject(appLock)
                    .environmentObject(recentlyDeleted)
                    .environmentObject(social)
                    .environmentObject(aiDJ)
                    .environmentObject(silenceTrim)
                    .environmentObject(discordVerification)
                    .opacity(showLaunch ? 0 : 1)
                    .animation(.easeInOut(duration: 0.4), value: showLaunch)

                if showLaunch {
                    LaunchView(isLoading: $showLaunch)
                        .environmentObject(account)
                        .environmentObject(libraryManager)
                        .environmentObject(player)
                        .transition(.opacity)
                }

                // Outermost layer — covers the launch screen too, so locking
                // takes effect the instant the app becomes active again, not
                // only once the launch/loading sequence finishes.
                if appLock.isEnabled && !appLock.isUnlocked {
                    AppLockView()
                        .environmentObject(appLock)
                        .transition(.opacity)
                        .zIndex(1)
                }

                // Topmost layer, above even AppLockView — see
                // `isSnapshotBlurred`'s doc comment. Deliberately no
                // `.transition`/opacity animation: this has to already be
                // fully opaque by the time the OS captures the App Switcher
                // snapshot, not still fading in.
                if isSnapshotBlurred {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .overlay(
                            Image("AppIconDisplay")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .opacity(0.5)
                        )
                        .zIndex(2)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: showLaunch)
            .animation(.easeInOut(duration: 0.25), value: appLock.isUnlocked)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { phase in
                if phase == .inactive {
                    isSnapshotBlurred = true
                } else if phase == .active {
                    isSnapshotBlurred = false
                }
                if phase == .background {
                    appLock.lock()
                    // Do not start full-library tagging or audio conversion
                    // while the app is transitioning to the background.
                    // Those file-heavy passes compete with suspension and
                    // caused the UI to stall whenever the app was backgrounded.
                    // The registered BGProcessingTask and the foreground
                    // maintenance loop handle this work without blocking the
                    // transition.
                    LumisoundTrackVaultService.scheduleNext()
                    // Submitted as the app leaves, which is exactly when an
                    // unfinished playlist needs a way back in — and unlike the
                    // launch `.task`'s copy of this call, nothing can cancel this
                    // before it runs. Re-submitting replaces the outstanding
                    // request for the same identifier rather than queueing a
                    // second one, so doing it on every backgrounding is free.
                    BackgroundRefreshService.scheduleNextDownloadCatchUp()
                    // Same reasoning for the refresh task: the launch path's
                    // scheduleNext() is behind a 3s sleep and an update check, so
                    // a quick open-and-close could leave nothing scheduled at all.
                    BackgroundRefreshService.scheduleNext()
                } else if phase == .active {
                    // Take the diagnostics snapshot that came due while the
                    // app was suspended (its main-run-loop timer doesn't fire
                    // there). No-op unless a full interval has elapsed.
                    DiagnosticsSnapshotService.noteDidBecomeActive()
                    // Catch-all safety net for background downloads: covers
                    // both "silent push never arrived" (Apple doesn't
                    // guarantee delivery/timing) and jobs that finished
                    // between BGAppRefreshTask runs. Cheap when there's
                    // nothing pending (a single GET request).
                    // Reconcile, THEN resume — same ordering and same reasoning as
                    // the launch path above (a finished-but-uncollected job must
                    // be imported before the resume pass diffs the library, or it
                    // re-downloads it).
                    //
                    // Resuming here is the fix for the case users actually hit:
                    // iOS suspending the app mid-pass. The launch `.task` only
                    // fires on a COLD launch, so before this, coming back to a
                    // suspended app left a part-finished playlist with no trigger
                    // at all — the user had to force-quit and reopen, or wait for
                    // a background slot iOS may never grant.
                    Task {
                        await streaming.reconcilePendingDownloads()
                        await TrackedPlaylistStore.shared.runAutoDownloads(
                            streaming: streaming, library: libraryManager
                        )
                    }
                    // An announcement's window can open while the app is simply
                    // sitting suspended, which for a music app can be days — so
                    // relying on a cold launch alone would let a three-day
                    // announcement expire unseen by exactly the people who use
                    // the app most. Costs one GET that normally returns [].
                    Task { await account.showPendingAnnouncements() }
                }
            }
            .task {
                    // Configure background logger (idempotent — safe if .task fires multiple times)
                    AppLogger.shared.configure(bridgeURL: streaming.bridgeURL)

                    // Genuine 5-minute foreground check for tracks ready to
                    // convert to the Lumisound-exclusive extension — idempotent,
                    // safe to call every time this .task re-fires.
                    LumisoundTrackVaultService.startFiveMinuteForegroundLoop()

                    // Restore audio settings — player must be configured before any resume.
                    player.restoreDefaultAudioSettings(PersistenceService.shared.loadAudioSettings() ?? AudioSettings())

                    // Wire the sleep-timer fade to the player's volume control.
                    sleepTimer.getVolume = { player.audioSettings.volume }
                    sleepTimer.setVolume = { player.audioSettings.volume = $0 }
                    sleepTimer.getRate   = { player.audioSettings.speed }
                    sleepTimer.setRate   = { player.audioSettings.speed = $0 }
                    sleepTimer.onExpire  = { player.pause() }

                    // Wire mood service to library so it can access songs.
                    moodService.libraryManager = libraryManager

                    // Wire player to library so it can resolve track BPM for
                    // beat-aware crossfades.
                    player.libraryManager = libraryManager

                    // Wire SharePlay up to live app state, same reason App
                    // Intents use weak `.shared` singletons — this needs to
                    // reach the player/library/streaming instances constructed
                    // by this View's @StateObjects.
                    sharePlay.player = player
                    sharePlay.library = libraryManager
                    sharePlay.streaming = streaming

                    discordVerification.attach(account: account)
                    if account.isLoggedIn {
                        Task { await discordVerification.refresh() }
                    }

                    // Wire AI DJ Mode's volume ducking to the same
                    // `audioSettings.volume` knob the sleep-timer fade uses.
                    aiDJ.getVolume = { player.audioSettings.volume }
                    aiDJ.setVolume = { player.audioSettings.volume = $0 }
                    aiDJ.attach(player: player, account: account)
                    silenceTrim.attach(player: player)
                    LongTrackResumeService.shared.attach(player: player)

                    // Route transport commands from the watch companion to the player.
                    PhoneWatchSync.shared.commandHandler = { command in
                        switch command {
                        case "toggle":   player.togglePlayPause()
                        case "next":     player.skipToNext()
                        case "previous": player.skipToPrevious()
                        default:         break
                        }
                    }

                    // Auto-scan for corrupt files immediately, then hourly
                    // for the rest of the session (non-blocking, all users). Both this
                    // and the duplicate scan below are Aria Lumi Primary: the timer
                    // just keeps her checking continuously, but the actual
                    // corrupt/duplicate calls (auto-delete, acoustic match + auto-remove)
                    // are Aria's decisions, not raw heuristics acting alone.
                    CorruptFileFinderService.shared.startPeriodicScanning()
                    DuplicateFinderService.shared.startPeriodicScanning()

                    // Aria's cloud-library housekeeping counterpart to the
                    // local corrupt-file scan above — once a day, at most.
                    Task { await AriaCloudCleanupService.runIfNeeded() }

                    // Sweep anything past its 30-day recovery window — cheap
                    // no-op most launches, matters for anyone who deleted
                    // tracks a month ago and never opened Recently Deleted.
                    recentlyDeleted.purgeExpired()

                    // Periodically retry online metadata lookups for imported
                    // tracks still missing artist/album/genre/year (e.g. after
                    // restoring files from a backup).
                    libraryManager.startPeriodicMetadataReenrichment()

                    // Every 3 minutes, re-read embedded tags for a small rotating
                    // batch of imported tracks so externally-updated metadata
                    // (e.g. a bridge re-tag) surfaces without a full rescan.
                    libraryManager.startPeriodicMetadataRefresh()

                    // Auto-download new tracks from any tracked playlists that have it
                    // enabled (throttled internally; each playlist does its own fresh
                    // library scan before deciding what's new — see
                    // TrackedPlaylistStore.runAutoDownloads — so it doesn't need to wait
                    // for anything above to finish first). Fired as its own independent
                    // Task rather than awaited in this sequential chain: it used to run
                    // dead last, after account sync, notification-permission prompts,
                    // bridge health checks, a 3s sleep, and a GitHub update check —  a
                    // normal "open the app, glance at it, close it" session routinely got
                    // this whole .task cancelled by view disappearance before ever
                    // reaching that line, so auto-download silently never ran. A plain
                    // Task{} is unstructured — it starts immediately and keeps running
                    // independently of this .task's own cancellation, so it actually gets
                    // a chance to finish even on a quick app open.
                    //
                    // Reconciliation runs FIRST and is awaited before the
                    // auto-download pass, rather than the two racing as separate
                    // Tasks as they used to. They are not independent: a job the
                    // bridge already finished while the app was away is a track
                    // the resume pass must see as OWNED. Started in parallel, the
                    // pass could resolve the playlist and diff it against the
                    // library before reconciliation had imported those files, and
                    // then ask the bridge to download tracks that were sitting
                    // finished and waiting to be collected.
                    //
                    // Pick up whatever finished while the app was closed (see
                    // StreamingService+PendingDownloads) — the scenePhase ==
                    // .active handler covers returning to the foreground later,
                    // but that onChange doesn't fire for the very first launch.
                    Task {
                        await streaming.reconcilePendingDownloads()
                        await TrackedPlaylistStore.shared.runAutoDownloads(
                            streaming: streaming, library: libraryManager
                        )
                        // Keeps a long playlist progressing for as long as the
                        // app stays open, instead of depending on iOS granting
                        // background time. See startForegroundResumeLoop.
                        TrackedPlaylistStore.shared.startForegroundResumeLoop(
                            streaming: streaming, library: libraryManager
                        )
                    }

                    // If logged in, pull latest state from DB as primary storage source.
                    if account.isLoggedIn {
                        await account.pullSync(library: libraryManager, player: player)
                        account.startAutoPushTimer(library: libraryManager)
                        await account.loadAvatar(forceRefresh: true)
                    }

                    // Push per-track audio settings to the server whenever they change.
                    player.onTrackAudioSettingsChanged = { [weak account, weak libraryManager, weak player] in
                        guard let account, let libraryManager, let player else { return }
                        account.schedulePush(
                            library: libraryManager,
                            audioSettings: player.defaultAudioSettings,
                            trackAudioSettings: player.perTrackAudioSettings
                        )
                    }

                    // Request device-notification authorization and mirror any
                    // existing unread server-inbox items to device notifications.
                    await NotificationService.shared.requestAuthorization()
                    if account.isLoggedIn {
                        let unread = await account.fetchNotifications(unreadOnly: true)
                        NotificationService.shared.syncServerNotifications(unread)
                        // Broadcast in-app toasts (see
                        // AccountService+Announcements). Placed after the
                        // notification sync rather than earlier in this task so
                        // an announcement toast can't appear over a still-loading
                        // first screen, and unstructured so a quick
                        // open-and-close cancelling this `.task` doesn't consume
                        // the announcement without showing it.
                        Task { await account.showPendingAnnouncements() }
                    }

                    // Start periodic bridge health checks.
                    bridgeHealth.startPeriodicChecks(streaming: streaming)

                    // Check for updates after a brief delay.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await updater.checkForUpdates()

                    // Queue the periodic background check (subscriptions +
                    // tracked playlists) — see BackgroundRefreshService.
                    BackgroundRefreshService.scheduleNext()
                    // Long-form download catch-up (a BGProcessingTask, minutes
                    // rather than the refresh task's ~30s) — see
                    // BackgroundRefreshService.downloadTaskIdentifier. Also
                    // submitted from the `.background` scenePhase handler, which
                    // is the reliable one: everything here runs after a 3s sleep
                    // and an update check, inside a `.task` that a quick "open and
                    // close" cancels before reaching this line.
                    BackgroundRefreshService.scheduleNextDownloadCatchUp()
                    LumisoundTrackVaultService.scheduleNext()

                    // Standing "what does a real session look like right
                    // now" telemetry — playback/profile/social state and
                    // which settings are actually having an effect, on a
                    // 5-minute interval. See DiagnosticsSnapshotService's
                    // header comment for why this exists (no Xcode/device
                    // debugger in this project's dev environment).
                    DiagnosticsSnapshotService.start()
                }
                .onAppear {
                    bgService.loadSettings()
                    if bgService.isEnabled, !bgService.images.isEmpty {
                        bgService.startShuffling()
                    }
                }
                // DB as primary storage: push to server whenever favorites or playlists change.
                // schedulePush debounces rapid bursts (e.g. initial library scan) into one write.
                .onChange(of: libraryManager.favoriteSongIDs) { _ in
                    account.schedulePush(library: libraryManager)
                }
                .onChange(of: libraryManager.playlists) { _ in
                    account.schedulePush(library: libraryManager)
                }
                // Persist audio settings to local AND DB when they change. While a
                // per-track override is active, `audioSettings` reflects that
                // track's settings rather than the global default — only persist
                // the latter as the global default (`player.defaultAudioSettings`
                // is unaffected by per-track overrides); the per-track values are
                // persisted separately via `onTrackAudioSettingsChanged` above.
                .onChange(of: player.audioSettings) { newSettings in
                    if player.isUsingTrackAudioSettings {
                        PersistenceService.shared.saveAudioSettings(player.defaultAudioSettings)
                    } else {
                        PersistenceService.shared.saveAudioSettings(newSettings)
                    }
                    account.schedulePush(
                        library: libraryManager,
                        audioSettings: player.defaultAudioSettings,
                        trackAudioSettings: player.perTrackAudioSettings
                    )
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didEnterBackgroundNotification
                    )
                ) { _ in
                    PersistenceService.shared.saveAudioSettings(player.defaultAudioSettings)
                }
                .onReceive(sleepTimer.$didExpire) { expired in
                    if expired { player.pause() }
                }
                // Auto-Radio: when the queue ends and autoRadioEnabled is on,
                // create a contextual station from the last-played song and
                // the account's real listening signals.
                .onReceive(player.$autoRadioSeed.compactMap { $0 }) { seed in
                    player.clearAutoRadioSeed()
                    guard player.autoRadioEnabled else { return }
                    Task {
                        appLog("Auto-radio: seeding from \"\(seed.displayName)\" by \(seed.artistName)", category: "audio")
                        let seedBPM = await libraryManager.bpm(for: seed)
                        let station = await account.fetchAutomaticStation(
                            seed: StationSeed(song: seed, bpm: seedBPM)
                        )
                        // Preserve the signed-out/offline behavior of the
                        // original Auto-Radio path; the richer station API is
                        // an enhancement, not a prerequisite for playback.
                        let tracks: [StreamTrack]
                        let stationTitle: String
                        if let station {
                            tracks = station.tracks
                            stationTitle = station.title
                        } else {
                            tracks = await streaming.relatedTracks(
                                query: "\(seed.artistName) \(seed.displayName)",
                                source: "youtube",
                                limit: 5
                            )
                            stationTitle = "fallback radio"
                        }
                        guard !tracks.isEmpty else {
                            appLog("Auto-radio: no results", category: "audio")
                            return
                        }
                        var appendedCount = 0
                        for track in tracks {
                            guard let url = try? await streaming.streamURL(for: track) else { continue }
                            // Tagged `.autoContinuation` (not the default `.manual`) so these
                            // land in the Queue UI's "Up Next" section, not "Manually Queued" —
                            // see QueueSource / AudioPlayerManager+Queue.appendToQueue.
                            player.appendToQueue(song: streaming.toSong(track: track, streamURL: url), source: .autoContinuation)
                            appendedCount += 1
                        }
                        if appendedCount > 0, !player.isPlaying { player.skipToNext() }
                        appLog("Auto-radio: appended \(appendedCount) track(s) from \(stationTitle)", category: "audio")
                    }
                }
                // When the user logs in after launch, start the auto-push timer and load avatar.
                .onReceive(account.$isLoggedIn) { loggedIn in
                    guard loggedIn else {
                        account.stopAutoPushTimer()
                        return
                    }
                    account.startAutoPushTimer(library: libraryManager)
                    Task { await account.loadAvatar(forceRefresh: true) }
                    Task { await discordVerification.refresh() }
                }
        }
    }
}
