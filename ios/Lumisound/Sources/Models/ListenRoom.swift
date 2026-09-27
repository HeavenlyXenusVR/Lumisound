import Foundation

// MARK: - Listening room models
//
// Mirrors the bridge's /rooms endpoints. Decoded with explicit CodingKeys rather
// than a global snake_case strategy, because this app's JSONDecoder is used bare
// in dozens of places and quietly changing its key policy would reach all of them.

/// One member currently in a room.
struct RoomParticipant: Codable, Identifiable, Equatable {
    let userId: String
    let username: String?
    let displayName: String?
    let isHost: Bool

    var id: String { userId }

    /// What to actually put on screen. The server already coalesces
    /// display_name → username, but both are optional in the payload (the join is
    /// a LEFT JOIN, so a deleted account yields nulls rather than dropping the
    /// row), and a blank row reads as a bug.
    var label: String { displayName ?? username ?? "Someone" }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case displayName = "display_name"
        case isHost = "is_host"
    }
}

/// A line in the room's history: a chat message, a track change, or someone
/// arriving/leaving.
struct RoomEvent: Codable, Identifiable, Equatable {
    let eventType: String
    let title: String?
    let artist: String?
    let message: String?
    let createdAt: Date?
    let userId: String?
    let username: String?
    let displayName: String?

    /// Composed rather than server-supplied: `ios_room_events.id` is a bigint the
    /// endpoint doesn't return, and events are append-only, so type+time+author is
    /// stable enough to key a list on without changing the API.
    var id: String {
        "\(eventType)|\(createdAt?.timeIntervalSince1970 ?? 0)|\(userId ?? "")|\(message ?? title ?? "")"
    }

    var author: String { displayName ?? username ?? "Someone" }
    var isChat: Bool { eventType == "chat" }

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case title, artist, message
        case createdAt = "created_at"
        case userId = "user_id"
        case username
        case displayName = "display_name"
    }
}

/// A track suggested into the room's shared queue.
struct RoomQueueItem: Codable, Identifiable, Equatable {
    let id: String
    let trackURL: String?
    let title: String
    let artist: String?
    var votes: Int
    let addedByUserId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackURL = "track_url"
        case title, artist, votes
        case addedByUserId = "added_by_user_id"
    }
}

/// The room's playback state as the host last reported it.
struct RoomState: Codable, Equatable {
    let roomCode: String
    let trackURL: String?
    let title: String?
    let artist: String?
    let positionSeconds: Double?
    let isPlaying: Bool
    /// When the host last reported `positionSeconds`.
    let updatedAt: Date?
    /// The server's clock at the moment it answered.
    let serverTime: Date?
    let isHost: Bool?
    let participants: [RoomParticipant]?

    enum CodingKeys: String, CodingKey {
        case roomCode = "room_code"
        case trackURL = "track_url"
        case title, artist
        case positionSeconds = "position_seconds"
        case isPlaying = "is_playing"
        case updatedAt = "updated_at"
        case serverTime = "server_time"
        case isHost = "is_host"
        case participants
    }

    /// Where playback actually is *now*, accounting for how long ago the host
    /// reported this and for the two devices' clocks disagreeing.
    ///
    /// The naive version of this — seek to `positionSeconds` — is wrong by however
    /// long the report took to arrive plus however long ago it was made, which for
    /// somebody joining mid-track is the whole point of the feature failing.
    ///
    /// `serverTime` is what makes it safe to subtract: comparing `updatedAt`
    /// against the *device's* clock would fold in any offset between the two
    /// machines, and phone clocks are routinely seconds out. Measuring the offset
    /// once against the same response the timestamp came in keeps this to
    /// transit time.
    ///
    /// Only advanced while playing — a paused host's position does not move, and
    /// adding elapsed time to it would run a follower off the end of the track.
    func resolvedPosition(now: Date = Date()) -> Double? {
        guard let base = positionSeconds else { return nil }
        guard isPlaying, let updatedAt, let serverTime else { return base }
        let clockOffset = serverTime.timeIntervalSince(now)
        let elapsed = now.addingTimeInterval(clockOffset).timeIntervalSince(updatedAt)
        // Negative elapsed means the clocks or the round trip lied; trusting it
        // would seek backwards. Clamped rather than believed.
        return base + max(0, elapsed)
    }
}
