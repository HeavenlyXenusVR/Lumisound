import Combine
import Foundation
import UIKit

// MARK: - ListenRoomService
//
// The client half of the bridge's shared-listening rooms. The server side existed
// for a long time with no client at all — every /rooms endpoint, three tables, and
// zero references from this app — so this is the first thing that makes the
// feature reachable.
//
// Deliberately push-first. The bridge fans room state, chat, queue changes,
// membership and closure over the same /ws/live socket `LiveUpdateService` already
// holds open (see `_push_room_event`), so the common case costs no polling at all.
// The heartbeat below is not a poll for state — it is this device telling the
// server it is still present, which is what keeps it in the member list and in the
// push audience. Its response carries the member list back only because it is
// already a round trip.
@MainActor
final class ListenRoomService: ObservableObject {

    static let shared = ListenRoomService()

    /// The room this device is currently in, if any.
    @Published private(set) var state: RoomState?
    @Published private(set) var participants: [RoomParticipant] = []
    @Published private(set) var events: [RoomEvent] = []
    @Published private(set) var queue: [RoomQueueItem] = []
    @Published private(set) var isHost = false
    @Published var errorMessage: String?
    /// Set when the host ends the room, so a follower's UI can say why it closed
    /// rather than silently emptying.
    @Published private(set) var closedByHost = false

    var roomCode: String? { state?.roomCode }
    var isInRoom: Bool { state != nil }

    /// Shorter than the server's 90s presence TTL by enough that one dropped
    /// request doesn't blink this device out of the room.
    private static let heartbeatInterval: TimeInterval = 30

    /// How often the host republishes its playback position.
    ///
    /// Followers compute their own position from `updated_at` plus elapsed time
    /// (see `RoomState.resolvedPosition`), so they do not need frequent updates to
    /// stay in sync — they need *recent enough* ones to survive a seek or a pause
    /// they missed. Every 15s keeps a late joiner within a few seconds without
    /// making a listening session a write-heavy workload on a shared bridge.
    private static let hostBroadcastInterval: TimeInterval = 15

    private var heartbeatTimer: Timer?
    private var hostBroadcastTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Decoding

    /// Shared decoder for room payloads.
    ///
    /// A custom date strategy because the bridge emits fractional seconds
    /// (`...874131+00:00`) and Foundation's `.iso8601` strategy rejects those
    /// outright — it would fail the whole decode, not just the date. Falls back to
    /// the non-fractional form, which is what a timestamp landing exactly on a
    /// second boundary serialises to.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: raw) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognised date: \(raw)"))
        }
        return d
    }()

    // MARK: - Lifecycle

    /// Subscribes to live room pushes. Called once at launch.
    func attachLiveUpdates() {
        LiveUpdateService.shared.onRoomEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleLive(event) }
        }
    }

    /// Creates a room around whatever this device is playing and becomes its host.
    @discardableResult
    func createRoom(player: AudioPlayerManager) async -> String? {
        guard let account = AccountService.shared, account.isLoggedIn else {
            errorMessage = "Sign in to start a listening room."
            return nil
        }
        struct Body: Encodable {
            let track_url: String?
            let title: String?
            let artist: String?
            let position_seconds: Double
            let is_playing: Bool
        }
        let song = player.currentSong
        let body = Body(
            track_url: song?.url?.absoluteString,
            title: song?.title,
            artist: (song?.artist.isEmpty ?? true) ? nil : song?.artist,
            position_seconds: player.position,
            is_playing: player.isPlaying
        )
        do {
            let data = try await account.makeRequest("/rooms", method: "POST", body: body)
            struct Created: Decodable { let room_code: String }
            let created = try JSONDecoder().decode(Created.self, from: data)
            appLog("ListenRoom: created room \(created.room_code)", category: "rooms")
            // Joining its own room is what registers the host in the participant
            // table — without it the host is absent from the member list and, more
            // importantly, absent from the push audience for everyone else's chat.
            await join(code: created.room_code, player: player)
            return created.room_code
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Joins an existing room by code and starts following it.
    func join(code: String, player: AudioPlayerManager) async {
        guard let account = AccountService.shared, account.isLoggedIn else {
            errorMessage = "Sign in to join a listening room."
            return
        }
        let normalised = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalised.count == 6 else {
            errorMessage = "A room code is six characters."
            return
        }
        closedByHost = false
        do {
            let data = try await account.makeRequest("/rooms/\(normalised)/join", method: "POST")
            let joined = try Self.decoder.decode(RoomState.self, from: data)
            state = joined
            participants = joined.participants ?? []
            isHost = joined.isHost ?? false
            errorMessage = nil
            appLog("ListenRoom: joined \(normalised) (host: \(isHost))", category: "rooms")
            await refreshEvents()
            await refreshQueue()
            startHeartbeat()
            if isHost { startHostBroadcast(player: player) }
        } catch let err as AccountError {
            errorMessage = err.statusCode == 404 ? "No room with that code." : err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Leaves the room (or closes it, if hosting).
    func leave(close: Bool = false) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        stopTimers()
        let shouldClose = close && isHost
        // Local state is cleared first, so the UI dismisses immediately rather
        // than waiting on a request that may be slow or fail. There is nothing to
        // roll back — presence times out server-side regardless.
        state = nil
        participants = []
        events = []
        queue = []
        isHost = false
        do {
            if shouldClose {
                _ = try await account.makeRequest("/rooms/\(code)", method: "DELETE")
            } else {
                _ = try await account.makeRequest("/rooms/\(code)/leave", method: "POST")
            }
        } catch {
            // Best-effort: the server drops this member on TTL anyway.
        }
    }

    // MARK: - Chat, queue, votes

    func sendChat(_ message: String) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        struct Body: Encodable { let message: String }
        do {
            _ = try await account.makeRequest("/rooms/\(code)/chat", method: "POST", body: Body(message: trimmed))
            // The sender is excluded from the push (they already know what they
            // said), so their own message is appended locally rather than waiting
            // for a refresh that would never mention it.
            let mine = RoomEvent(
                eventType: "chat", title: nil, artist: nil, message: trimmed,
                createdAt: Date(), userId: AccountService.shared?.currentUser?.id,
                username: AccountService.shared?.currentUser?.username,
                displayName: AccountService.shared?.currentUser?.displayName
                    ?? AccountService.shared?.currentUser?.username)
            events.append(mine)
        } catch let err as AccountError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func suggest(song: Song) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        struct Body: Encodable {
            let track_url: String?
            let title: String
            let artist: String?
        }
        do {
            _ = try await account.makeRequest(
                "/rooms/\(code)/queue", method: "POST",
                body: Body(track_url: song.url?.absoluteString, title: song.title,
                           artist: song.artist.isEmpty ? nil : song.artist))
            await refreshQueue()
        } catch let err as AccountError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggles this device's vote on a suggestion.
    func toggleVote(itemID: String) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        do {
            let data = try await account.makeRequest("/rooms/\(code)/queue/\(itemID)/vote", method: "POST")
            struct VoteResult: Decodable { let status: String; let votes: Int }
            let result = try JSONDecoder().decode(VoteResult.self, from: data)
            // Applied from the server's authoritative count rather than adjusted
            // locally: the endpoint is a toggle, so guessing the direction would
            // drift out of step the moment two taps race.
            if let idx = queue.firstIndex(where: { $0.id == itemID }) {
                queue[idx].votes = result.votes
                // Most votes first, then alphabetical so equal-vote items have a
                // stable order instead of shuffling on every re-sort.
                queue.sort { lhs, rhs in
                    lhs.votes != rhs.votes ? lhs.votes > rhs.votes : lhs.title < rhs.title
                }
            }
        } catch {
            await refreshQueue()
        }
    }

    // MARK: - Refresh

    func refreshEvents() async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        do {
            let data = try await account.makeRequest("/rooms/\(code)/events")
            struct Wrapper: Decodable { let events: [RoomEvent] }
            events = try Self.decoder.decode(Wrapper.self, from: data).events
        } catch {
            // Non-fatal: the history is supplementary to the live stream.
        }
    }

    func refreshQueue() async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        do {
            let data = try await account.makeRequest("/rooms/\(code)/queue")
            struct Wrapper: Decodable { let queue: [RoomQueueItem] }
            queue = try Self.decoder.decode(Wrapper.self, from: data).queue
        } catch {
            // Non-fatal, as above.
        }
    }

    // MARK: - Live push handling

    private func handleLive(_ event: [String: Any]) {
        let type = event["type"] as? String
        // Guard on the room code: a stale push from a room this device already
        // left would otherwise overwrite the current one's state.
        if let code = event["room_code"] as? String, let mine = roomCode, code != mine { return }

        switch type {
        case "room_state":
            guard let current = state else { return }
            state = RoomState(
                roomCode: current.roomCode,
                trackURL: event["track_url"] as? String ?? current.trackURL,
                title: event["title"] as? String ?? current.title,
                artist: event["artist"] as? String ?? current.artist,
                positionSeconds: event["position_seconds"] as? Double ?? current.positionSeconds,
                isPlaying: event["is_playing"] as? Bool ?? current.isPlaying,
                // `as_of` is the server's own send time, so it replaces
                // `updatedAt` AND `serverTime` — the push has no round trip to
                // measure an offset from, and treating a fresh push as stale
                // would make a follower seek forward for no reason.
                updatedAt: Self.parseDate(event["as_of"] as? String) ?? Date(),
                serverTime: Self.parseDate(event["as_of"] as? String) ?? Date(),
                isHost: current.isHost,
                participants: current.participants
            )
        case "room_chat":
            let incoming = RoomEvent(
                eventType: "chat", title: nil, artist: nil,
                message: event["message"] as? String,
                createdAt: Self.parseDate(event["created_at"] as? String) ?? Date(),
                userId: event["user_id"] as? String,
                username: event["username"] as? String,
                displayName: event["display_name"] as? String)
            events.append(incoming)
        case "room_queue":
            Task { await refreshQueue() }
        case "room_members":
            Task { await refreshParticipants() }
        case "room_closed":
            closedByHost = true
            Task { await leave() }
        default:
            break
        }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    private func refreshParticipants() async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        do {
            let data = try await account.makeRequest("/rooms/\(code)/heartbeat", method: "POST")
            struct Wrapper: Decodable { let participants: [RoomParticipant] }
            participants = try Self.decoder.decode(Wrapper.self, from: data).participants
        } catch {
            // Non-fatal.
        }
    }

    // MARK: - Timers

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshParticipants() }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    private func startHostBroadcast(player: AudioPlayerManager) {
        hostBroadcastTimer?.invalidate()

        // Timer-driven rather than purely observing the player. A track change and
        // a pause both need to reach followers promptly, but a seek produces no
        // discrete event to observe at all — only a position that is suddenly
        // different — so a periodic republish is the only thing that covers every
        // case. The observers below exist to make the common, visible changes
        // immediate instead of waiting up to a full interval.
        let t = Timer(timeInterval: Self.hostBroadcastInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.broadcast(player: player) }
        }
        RunLoop.main.add(t, forMode: .common)
        hostBroadcastTimer = t

        cancellables.removeAll()
        player.$currentSong
            .removeDuplicates { $0?.id == $1?.id }
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.broadcast(player: player) }
            }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.broadcast(player: player) }
            }
            .store(in: &cancellables)
    }

    private func broadcast(player: AudioPlayerManager) async {
        guard isHost, let account = AccountService.shared, let code = roomCode else { return }
        struct Body: Encodable {
            let track_url: String?
            let title: String?
            let artist: String?
            let position_seconds: Double
            let is_playing: Bool
        }
        let song = player.currentSong
        do {
            _ = try await account.makeRequest(
                "/rooms/\(code)", method: "PUT",
                body: Body(track_url: song?.url?.absoluteString,
                           title: song?.title,
                           artist: (song?.artist.isEmpty ?? true) ? nil : song?.artist,
                           position_seconds: player.position,
                           is_playing: player.isPlaying))
        } catch {
            // Silent, like PresenceService's heartbeat: this fires on a timer
            // regardless of network state and must never interrupt playback.
        }
    }

    private func stopTimers() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        hostBroadcastTimer?.invalidate(); hostBroadcastTimer = nil
        cancellables.removeAll()
    }
}
