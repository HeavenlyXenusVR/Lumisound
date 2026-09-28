import Foundation
import UIKit

// MARK: - PresenceService
//
// Lightweight polling-based presence: this device periodically tells the
// bridge "I'm online, here's what I'm playing" (POST /api/social/presence),
// and separately polls a *batched* endpoint for friends' presence
// (GET /api/social/presence/friends) — one request covers every friend, so
// a long friends list never means one network call per friend on a timer
// (that exact per-item-synchronous-call-in-a-loop shape is a known main-
// thread-hang bug class in this codebase; see hasLocalCopy(of:) history).
//
// Two independent timers:
//   - `heartbeatTimer` — this device's own "I'm online" signal. Started by
//     ContentView (the one view mounted for the app's entire foreground
//     lifetime) on appear/login, stopped on logout. A best-effort
//     "going offline" beacon fires from ContentView's background/terminate
//     handling via `sendGoingOffline`.
//   - `friendsPollTimer` — only runs while some screen actually wants to
//     *display* friends' presence (FriendsListView, PublicProfileView).
//     Those views start/stop it in onAppear/onDisappear so it doesn't poll
//     forever in the background for no on-screen reason.
@MainActor
final class PresenceService: ObservableObject {

    /// A singleton (rather than only a ContentView-owned `@StateObject`) so
    /// `LiveUpdateService`'s presence-event callback — wired up from
    /// `AccountService`, which has no reference to whatever `@StateObject`
    /// instance a given view hierarchy created — has a stable place to
    /// deliver live pushes to. `ContentView` wraps this same instance in
    /// its `@StateObject` (see its declaration) rather than constructing a
    /// second, disconnected one.
    static let shared = PresenceService()

    @Published private(set) var friendsPresence: [SocialPresence] = []

    /// How often this device reports its own state while foregrounded.
    static let heartbeatInterval: TimeInterval = 45
    /// Safety-net poll interval for a visible friends/presence screen —
    /// `LiveUpdateService` now delivers presence changes the instant they
    /// happen (see `applyLivePresence`), so this only needs to catch up
    /// after a dropped/reconnecting socket, not carry the whole feature on
    /// its own. Widened from 30s now that it's a fallback, not the primary
    /// mechanism.
    static let friendsPollInterval: TimeInterval = 120

    private var heartbeatTimer: Timer?
    private var friendsPollTimer: Timer?

    // MARK: - Self heartbeat

    func startHeartbeat(account: AccountService, player: AudioPlayerManager) {
        stopHeartbeat()
        guard account.isLoggedIn else { return }
        Task { [weak self, weak account, weak player] in
            guard let self, let account, let player else { return }
            await self.sendHeartbeat(account: account, player: player)
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self, weak account, weak player] _ in
            Task { @MainActor [weak self, weak account, weak player] in
                guard let self, let account, let player, account.isLoggedIn,
                      UIApplication.shared.applicationState == .active else { return }
                await self.sendHeartbeat(account: account, player: player)
            }
        }
        // Lets iOS batch this wake-up with others (battery).
        heartbeatTimer?.tolerance = (Self.heartbeatInterval) * 0.1
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Best-effort "going offline" signal — fired from `didEnterBackground`.
    /// Not guaranteed to complete (the process may suspend mid-request), but
    /// costs nothing to try; if it never lands, the 90s server-side
    /// freshness window (see `_SOCIAL_PRESENCE_FRESH_SECONDS` in main.py)
    /// still makes this device read as offline shortly after this device
    /// simply stops sending heartbeats.
    func sendGoingOffline(account: AccountService) {
        guard account.isLoggedIn else { return }
        struct Body: Encodable {
            let is_playing = false
            let now_playing_title: String? = nil
            let now_playing_artist: String? = nil
            let going_offline = true
        }
        Task { [weak account] in
            guard let account else { return }
            _ = try? await account.makeRequest("/api/social/presence", method: "POST", body: Body())
        }
    }

    private func sendHeartbeat(account: AccountService, player: AudioPlayerManager) async {
        struct Body: Encodable {
            let is_playing: Bool
            let now_playing_title: String?
            let now_playing_artist: String?
            let now_playing_artwork_url: String?
            let going_offline: Bool = false
        }
        let song = player.currentSong
        let body = Body(
            is_playing: player.isPlaying && song != nil,
            now_playing_title: song?.title,
            now_playing_artist: (song?.artist.isEmpty ?? true) ? nil : song?.artist,
            // Deterministic from sourceTrackID alone — no file I/O, no
            // network fetch here (see Song.youtubeThumbnailURL). `nil` for
            // non-YouTube sources/local imports, same as title/artist are
            // `nil` while nothing's playing.
            now_playing_artwork_url: song?.youtubeThumbnailURL?.absoluteString
        )
        do {
            _ = try await account.makeRequest("/api/social/presence", method: "POST", body: body)
        } catch {
            // Silent — same "don't spam logs/interrupt playback" reasoning as
            // AccountService+Avatar's pushPlaybackState, since this fires
            // repeatedly on a timer regardless of network state.
        }
    }

    // MARK: - Friends' presence (batched)

    func startFriendsPolling(account: AccountService) {
        stopFriendsPolling()
        guard account.isLoggedIn else { return }
        Task { [weak self, weak account] in
            guard let self, let account else { return }
            await self.fetchFriendsPresence(account: account)
        }
        friendsPollTimer = Timer.scheduledTimer(withTimeInterval: Self.friendsPollInterval, repeats: true) { [weak self, weak account] _ in
            Task { @MainActor [weak self, weak account] in
                // Optimization pass: this used to fire an HTTP request every
                // 30s indefinitely while backgrounded (this app supports
                // background audio playback, so "backgrounded" is a common,
                // long-lived state, not a brief transient one) — matches
                // `heartbeatTimer`'s existing `applicationState == .active`
                // gate right above this function.
                guard let self, let account, account.isLoggedIn,
                      UIApplication.shared.applicationState == .active else { return }
                await self.fetchFriendsPresence(account: account)
            }
        }
        // Lets iOS batch this wake-up with others (battery).
        friendsPollTimer?.tolerance = (Self.friendsPollInterval) * 0.1
    }

    func stopFriendsPolling() {
        friendsPollTimer?.invalidate()
        friendsPollTimer = nil
    }

    func fetchFriendsPresence(account: AccountService) async {
        guard account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/presence/friends")
            friendsPresence = try JSONDecoder().decode(SocialFriendsPresenceResponse.self, from: data).presence
        } catch {
            appWarn("PresenceService: friends presence fetch failed: \(error.localizedDescription)", category: "social")
        }
    }

    /// Applies a presence update pushed live over `LiveUpdateService`'s
    /// WebSocket channel — replaces the matching entry (or inserts one) in
    /// `friendsPresence` in place, no network round trip. This is why
    /// `friendsPollTimer` no longer needs to run every 30s: a friend's
    /// state now updates the instant their own heartbeat lands server-side,
    /// and the poll timer only exists as a safety net for a dropped socket.
    func applyLivePresence(_ presence: SocialPresence) {
        if let index = friendsPresence.firstIndex(where: { $0.userId == presence.userId }) {
            friendsPresence[index] = presence
        } else {
            friendsPresence.append(presence)
        }
    }

    /// Single-user lookup — used by `PublicProfileView` for one profile at a
    /// time (not on a tight loop; the view's own onAppear/onDisappear starts
    /// and stops a normal single-target poll, same shape as the friends one).
    func fetchPresence(userId: String, account: AccountService) async -> SocialPresence? {
        guard account.isLoggedIn else { return nil }
        do {
            let data = try await account.makeRequest("/api/social/presence/\(userId)")
            return try JSONDecoder().decode(SocialPresence.self, from: data)
        } catch {
            appWarn("PresenceService: presence fetch failed for \(userId): \(error.localizedDescription)", category: "social")
            return nil
        }
    }

    deinit {
        heartbeatTimer?.invalidate()
        friendsPollTimer?.invalidate()
    }
}
