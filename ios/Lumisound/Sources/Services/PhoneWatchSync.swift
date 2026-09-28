import Foundation
import WatchConnectivity
import UIKit

// MARK: - PhoneWatchSync (iOS side)
//
// Pushes Now Playing state to the paired watch companion (mirrors the
// WidgetDataService pattern) and routes transport commands coming back from the
// watch to the player via `commandHandler`. Entirely additive — if no watch is
// paired, every call is a cheap no-op.

@MainActor
final class PhoneWatchSync: NSObject, ObservableObject {
    static let shared = PhoneWatchSync()

    /// Set by the app to route watch commands ("toggle"/"next"/"previous") to the player.
    var commandHandler: ((String) -> Void)?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        startAccountHandoffPolling()
    }

    func update(song: Song?, isPlaying: Bool, artwork: UIImage?) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var ctx: [String: Any] = [
            "title": song?.displayName ?? "",
            "artist": song?.artistName ?? "",
            "isPlaying": isPlaying,
        ]
        // Mirrors whichever Lua theme preset is active (see LuaThemeEngine)
        // so the watch's transport buttons/progress match the phone's
        // accent instead of always using the system default tint. Omitted
        // entirely when no preset is active — the watch just keeps its
        // existing default in that case.
        if let accentHex = LuaThemeEngine.shared.activeAccentHex {
            ctx["accentColorHex"] = accentHex
        }
        if let artwork, let data = Self.thumbnailJPEG(artwork) {
            ctx["artwork"] = data
        } else {
            ctx["clearArtwork"] = true
        }
        try? session.updateApplicationContext(ctx)
    }

    /// Downsizes artwork to a small JPEG so it fits comfortably in the
    /// application-context payload. `maxDim` is in physical pixels — the
    /// previous naive resize (no explicit renderer scale) silently rendered
    /// at the phone's screen scale, tripling the payload's pixel dimensions
    /// (140 → 420px). 240px covers the watch's artwork slot (~120pt @2x)
    /// exactly.
    private static func thumbnailJPEG(_ image: UIImage, maxDim: CGFloat = 240) -> Data? {
        ImageDownsampler.jpegData(image, maxPixelSize: maxDim, compressionQuality: 0.5)
    }

    private func handle(_ payload: [String: Any]) {
        guard let cmd = payload["command"] as? String else { return }
        commandHandler?(cmd)
    }

    // MARK: - Account handoff (phone -> watch)
    //
    // Lets the watch's standalone "Watch Library" playback log in without the
    // user typing credentials, by relaying the phone's already-authenticated
    // bridge URL + bearer token. Uses `transferUserInfo` (a queued,
    // guaranteed-delivery channel), never `updateApplicationContext`, so it
    // can't clobber the Now Playing mirror context sent by
    // `update(song:isPlaying:artwork:)` above — that call fully replaces the
    // single application-context dictionary every time, so mixing account
    // keys into it would risk losing them on the next Now Playing update (or
    // vice versa). Polls `AccountService.shared` (the existing ambient weak
    // reference — see AccountService.swift) instead of requiring a new call
    // site in the login/logout flow, so this stays a self-contained, additive
    // change to this file alone.

    private var lastPushedToken: String?
    private var lastPushedBridgeURL: String?
    private var accountHandoffTimer: Timer?

    private func startAccountHandoffPolling() {
        accountHandoffTimer?.invalidate()
        pushAccountHandoffIfNeeded()
        accountHandoffTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            // Optimization pass: this ticked every 15s regardless of
            // foreground state — cheap per-tick (a couple of property
            // comparisons once activationState is confirmed), but with no
            // gate at all it ran indefinitely during background audio
            // playback, a common long-lived state for this app. Same
            // `applicationState == .active` gate PresenceService's
            // heartbeat/friends-poll timers already use.
            guard UIApplication.shared.applicationState == .active else { return }
            Task { @MainActor in self?.pushAccountHandoffIfNeeded() }
        }
        // Lets iOS batch this wake-up with others (battery).
        accountHandoffTimer?.tolerance = (15) * 0.1
    }

    private func pushAccountHandoffIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let token = AccountService.shared?.token
        let bridgeURL = AccountService.shared?.bridgeURL
        guard token != lastPushedToken || bridgeURL != lastPushedBridgeURL else { return }
        lastPushedToken = token
        lastPushedBridgeURL = bridgeURL

        // Built up as concrete non-optional values only — WCSession's transfer
        // dictionaries are plist-style and embedding a boxed `nil` (`x as Any`
        // where `x` is `nil`) is a real footgun here, not just a style nit.
        var payload: [String: Any] = [:]
        if let bridgeURL {
            payload["bridgeURL"] = bridgeURL
        }
        if let token {
            payload["accountToken"] = token
        } else {
            payload["accountTokenCleared"] = true
        }
        guard !payload.isEmpty else { return }
        session.transferUserInfo(payload)
    }
}

extension PhoneWatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handle(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.handle(userInfo) }
    }
}
