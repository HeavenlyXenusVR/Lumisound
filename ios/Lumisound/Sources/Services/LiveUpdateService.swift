import Foundation
import UIKit

// MARK: - LiveUpdateService
//
// A persistent WebSocket connection to the bridge's /ws/live push channel
// (see main.py's `_push_live_event`/`live_updates_ws`) — replaces most of
// what used to be pure interval polling with server-initiated "X changed,
// go refetch it" events, delivered the instant they happen instead of up
// to a whole poll interval later. Two systems this directly targets:
//   - Friends' online/now-playing presence (was a 30s poll — see
//     PresenceService) now updates the moment a friend's own heartbeat
//     lands server-side.
//   - The account sync pull (an explicitly documented source of a real UI
//     freeze on every 8-minute timer tick / launch / foreground — see
//     AccountService+Sync.swift) now only needs to run when the server
//     actually says something changed, not blindly on a timer.
// Falls back gracefully: if the socket is down (no network, bridge
// restarting, etc.) the existing polling timers (now at a much longer,
// safety-net-only interval — see PresenceService/AccountService) still
// catch up eventually, so nothing depends on this connection for
// correctness, only for how quickly a change is noticed.
@MainActor
final class LiveUpdateService: NSObject {
    static let shared = LiveUpdateService()

    /// Fired with the raw event dict whenever a message arrives. Consumers
    /// (AccountService, PresenceService) subscribe once at app launch.
    var onPresenceEvent: ((SocialPresence) -> Void)?
    var onNotificationEvent: (() -> Void)?
    var onSyncChangedEvent: (() -> Void)?
    /// Room pushes, delivered as the raw event dict.
    ///
    /// Typed loosely on purpose, unlike the presence callback above: the bridge
    /// sends five different `room_*` shapes (state, chat, queue, members, closed)
    /// and `ListenRoomService` is the only consumer, so decoding each into its own
    /// struct here would just move that service's switch into this file.
    var onRoomEvent: (([String: Any]) -> Void)?

    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var isStopped = true
    private var reconnectDelay: TimeInterval = 2
    private var currentBridgeURL: String?
    private var currentToken: String?

    private override init() { super.init() }

    func start(bridgeURL: String, token: String) {
        isStopped = false
        reconnectDelay = 2
        currentBridgeURL = bridgeURL
        currentToken = token
        connect()
    }

    func stop() {
        isStopped = true
        currentBridgeURL = nil
        currentToken = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func connect() {
        guard !isStopped, let bridgeURL = currentBridgeURL, let token = currentToken else { return }
        guard var components = URLComponents(string: bridgeURL) else { return }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/ws/live"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { return }

        let session = URLSession(configuration: .default)
        urlSession = session
        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        listenForMessages()
        startPing()
        appLog("LiveUpdateService: connecting", category: "network")
    }

    private func startPing() {
        pingTimer?.invalidate()
        // Keeps the connection alive through idle intermediaries (tunnels/
        // proxies routinely close a socket with no traffic for ~60-100s —
        // same class of edge timeout documented elsewhere in this codebase
        // for long-held HTTP requests). The server's own receive loop
        // (`await websocket.receive_text()`) just discards this — its
        // content doesn't matter, only that something arrives periodically.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.task?.send(.string("ping")) { _ in }
        }
        // Lets iOS batch this wake-up with others (battery).
        pingTimer?.tolerance = (25) * 0.1
    }

    private func listenForMessages() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Task { @MainActor [weak self] in
                    appWarn("LiveUpdateService: connection error: \(error.localizedDescription)", category: "network")
                    self?.scheduleReconnect()
                }
            case .success(let message):
                Task { @MainActor [weak self] in
                    self?.handle(message: message)
                    self?.listenForMessages()
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "presence":
            guard let userId = json["user_id"] as? String else { return }
            let presence = SocialPresence(
                userId: userId,
                online: json["online"] as? Bool ?? false,
                isPlaying: json["is_playing"] as? Bool ?? false,
                nowPlayingTitle: json["now_playing_title"] as? String,
                nowPlayingArtist: json["now_playing_artist"] as? String,
                nowPlayingArtworkURL: json["now_playing_artwork_url"] as? String,
                lastSeenAt: nil
            )
            onPresenceEvent?(presence)
        case "notification":
            onNotificationEvent?()
        case "sync_changed":
            onSyncChangedEvent?()
        case "room_state", "room_chat", "room_queue", "room_members", "room_closed":
            onRoomEvent?(json)
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard !isStopped else { return }
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        pingTimer?.invalidate()
        pingTimer = nil

        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }
}
