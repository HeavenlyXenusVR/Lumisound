import Foundation

// MARK: - Social Ecosystem models
//
// Backs the new /api/social/* endpoints on the bridge (see the "SOCIAL
// ECOSYSTEM" section at the end of ios-bridge/main.py). Deliberately kept
// separate from AccountModels.swift's pre-existing `ActivityEntry` /
// `TrendingTrack` (the global, non-friend-scoped /social/activity+discover
// feed) — these types are all friend/profile/presence-scoped.

/// One pinned "favorite song" on a profile (up to 5, ordered).
struct PinnedTrack: Codable, Identifiable, Equatable {
    var id: String { sourceTrackID ?? trackURL ?? "\(title)-\(artist ?? "")" }
    var sourceTrackID: String?
    var trackURL: String?
    var title: String
    var artist: String?
    var album: String?

    enum CodingKeys: String, CodingKey {
        case sourceTrackID = "source_track_id"
        case trackURL      = "track_url"
        case title, artist, album
    }
}

/// The signed-in user's own profile — GET /api/social/profile/me.
struct MySocialProfile: Decodable {
    let userId: String
    let bio: String?
    let mainAccentHex: String?
    let subAccentHex: String?
    let shareNowPlaying: Bool
    let pronouns: String?
    let statusEmoji: String?
    let statusText: String?
    let avatarFrame: String
    let showTopGenres: Bool
    let showGuestbook: Bool
    /// Feature: profile-customization-3 — opt-out toggle for the visitor
    /// stats card (default true) and opt-in toggle for the listening
    /// streak card (default false), mirroring `showTopGenres`'s precedent.
    let showVisitorStats: Bool
    let showListeningStats: Bool
    let memberSince: String?
    let pinnedTracks: [PinnedTrack]
    /// Own taste snapshot, always populated regardless of `showTopGenres` —
    /// see the bridge's `get_my_social_profile` doc comment: it's your own
    /// data, so the editor can preview the showcase card before turning it on.
    let topGenres: [String]
    let topArtists: [String]
    /// Always populated for /me regardless of `showListeningStats` — same
    /// "preview before you publish" reasoning as `topGenres`/`topArtists`.
    let listeningStreak: ListeningStreak
    /// Milestone achievement chips — always populated, no privacy toggle.
    let badges: [ProfileBadge]
    /// Always populated for /me regardless of `showVisitorStats`.
    let visitorCount: Int
    let recentVisitors: [ProfileVisitor]
    let featuredPlaylist: FeaturedPlaylist?
    /// Feature: profile-customization-4 — how strongly the profile's
    /// accent colors wash across the whole background (see
    /// `ProfileAccentBackgroundGlow`). One of "subtle"/"normal"/"vivid"/"off".
    let accentGlowIntensity: String
    /// Feature: profile-customization-5 — Discord-style "Avatar Decoration"
    /// (a looping animation overlaid ON the avatar itself, see
    /// `AvatarDecorationStyle`) and "Profile Effect" (a looping animation
    /// overlaid across the banner, see `ProfileEffectStyle`). One of each
    /// type's raw-value strings; "none" disables the overlay entirely.
    let avatarDecoration: String
    let profileEffect: String

    enum CodingKeys: String, CodingKey {
        case userId          = "user_id"
        case bio
        case mainAccentHex   = "main_accent_hex"
        case subAccentHex    = "sub_accent_hex"
        case shareNowPlaying = "share_now_playing"
        case pronouns
        case statusEmoji     = "status_emoji"
        case statusText      = "status_text"
        case avatarFrame     = "avatar_frame"
        case showTopGenres   = "show_top_genres"
        case showGuestbook   = "show_guestbook"
        case showVisitorStats   = "show_visitor_stats"
        case showListeningStats = "show_listening_stats"
        case memberSince     = "member_since"
        case pinnedTracks    = "pinned_tracks"
        case topGenres       = "top_genres"
        case topArtists      = "top_artists"
        case listeningStreak = "listening_streak"
        case badges
        case visitorCount    = "visitor_count"
        case recentVisitors  = "recent_visitors"
        case featuredPlaylist = "featured_playlist"
        case accentGlowIntensity = "accent_glow_intensity"
        case avatarDecoration = "avatar_decoration"
        case profileEffect    = "profile_effect"
    }
}

/// Another user's public profile — GET /api/social/profile/{user_id}.
struct PublicSocialProfile: Decodable, Identifiable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    let bio: String?
    let mainAccentHex: String?
    let subAccentHex: String?
    let pronouns: String?
    let statusEmoji: String?
    let statusText: String?
    let avatarFrame: String
    let showGuestbook: Bool
    let isFriend: Bool
    let memberSince: String?
    let pinnedTracks: [PinnedTrack]
    /// Empty unless the profile owner opted in via `show_top_genres` — the
    /// bridge withholds these entirely rather than sending real data the
    /// client is just expected not to display.
    let topGenres: [String]
    let topArtists: [String]
    /// Milestone achievement chips — always populated, no privacy toggle.
    let badges: [ProfileBadge]
    /// `nil` unless the profile owner opted in via `show_listening_stats`.
    let listeningStreak: ListeningStreak?
    /// `nil` unless the profile owner opted in via `show_visitor_stats`
    /// (the bridge withholds it entirely, same convention as `topGenres`).
    let visitorCount: Int?
    /// Only non-empty when the caller is actually a friend of the profile
    /// owner — see the bridge's `_profile_visitor_stats` doc comment.
    let recentVisitors: [ProfileVisitor]
    let featuredPlaylist: FeaturedPlaylist?
    /// Feature: profile-customization-4 — see `MySocialProfile`'s doc comment.
    let accentGlowIntensity: String
    /// Feature: profile-customization-5 — see `MySocialProfile`'s doc comment.
    let avatarDecoration: String
    let profileEffect: String
    /// Public flair, no privacy toggle — mirrors `badges`. See
    /// `DiscordVerificationService`/the bridge's `/api/discord/oauth/callback`.
    let discordVerified: Bool
    let discordUsername: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId        = "user_id"
        case username
        case displayName   = "display_name"
        case avatarURL     = "avatar_url"
        case bio
        case mainAccentHex = "main_accent_hex"
        case subAccentHex  = "sub_accent_hex"
        case pronouns
        case statusEmoji   = "status_emoji"
        case statusText    = "status_text"
        case avatarFrame   = "avatar_frame"
        case showGuestbook = "show_guestbook"
        case isFriend      = "is_friend"
        case memberSince   = "member_since"
        case pinnedTracks  = "pinned_tracks"
        case topGenres     = "top_genres"
        case topArtists    = "top_artists"
        case badges
        case listeningStreak = "listening_streak"
        case visitorCount    = "visitor_count"
        case recentVisitors  = "recent_visitors"
        case featuredPlaylist = "featured_playlist"
        case accentGlowIntensity = "accent_glow_intensity"
        case avatarDecoration = "avatar_decoration"
        case profileEffect    = "profile_effect"
        case discordVerified = "discord_verified"
        case discordUsername = "discord_username"
    }
}

/// Shared "public user" shape reused across search/friends/requests/blocks/
/// suggestions responses.
struct SocialUserRef: Codable, Identifiable, Equatable, Hashable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId      = "user_id"
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
    }
}

/// One entry from GET /api/social/friends.
struct SocialFriend: Decodable, Identifiable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    let friendsSince: String?
    /// Extra feature (friends-tab-expansion, 2026-07-21): a private nickname
    /// only the caller set/sees — never shown on the friend's own profile or
    /// to anyone else. `nil` when unset.
    var nickname: String?
    /// Extra feature: the caller's own custom tags/groups for this friend
    /// (e.g. "Close Friends", "Music Buddies") — private organizational
    /// labels, not visible to the friend. Always present (possibly empty)
    /// since GET /api/social/friends always includes it now.
    var tags: [String] = []

    var id: String { userId }

    /// What to actually display — the nickname when set, else the display
    /// name, else the raw username. Centralized here so every friend row/
    /// card automatically respects a nickname the moment one exists, without
    /// each call site re-implementing the same fallback chain.
    var effectiveName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return displayName ?? username
    }

    enum CodingKeys: String, CodingKey {
        case userId       = "user_id"
        case username
        case displayName  = "display_name"
        case avatarURL    = "avatar_url"
        case friendsSince = "friends_since"
        case nickname
        case tags
    }

    // Hand-written rather than relying on the synthesized Decodable
    // conformance: Swift's synthesis ignores a stored property's default
    // value (`= []`) when deciding whether a JSON key is required, so
    // `tags` would otherwise throw a `keyNotFound` decoding error against
    // any past/future response that omits it, instead of quietly falling
    // back to empty like the default expression implies everywhere else in
    // this struct's own Swift-side construction.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        friendsSince = try container.decodeIfPresent(String.self, forKey: .friendsSince)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

extension SocialFriend {
    var friendsSinceDate: Date? {
        guard let friendsSince else { return nil }
        return parseServerDate(friendsSince)
    }

    /// Extra feature: friendiversary callouts — derived entirely client-side
    /// from `friends_since` (no new backend endpoint needed for this one).
    /// Returns the number of full years since becoming friends when today is
    /// the exact month/day anniversary, else `nil`.
    var friendiversaryYears: Int? {
        guard let since = friendsSinceDate else { return nil }
        let cal = Calendar.current
        let today = Date()
        guard cal.component(.day, from: since) == cal.component(.day, from: today),
              cal.component(.month, from: since) == cal.component(.month, from: today)
        else { return nil }
        let years = cal.dateComponents([.year], from: since, to: today).year ?? 0
        return years >= 1 ? years : nil
    }
}

/// One entry from GET /api/social/friends/requests (incoming or outgoing).
struct SocialFriendRequest: Decodable, Identifiable {
    let requestId: String
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    let createdAt: String?

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case requestId  = "request_id"
        case userId     = "user_id"
        case username
        case displayName = "display_name"
        case avatarURL  = "avatar_url"
        case createdAt  = "created_at"
    }
}

/// Response from GET /api/social/friends/requests.
struct SocialFriendRequestsResponse: Decodable {
    let incoming: [SocialFriendRequest]
    let outgoing: [SocialFriendRequest]
}

/// One entry from GET /api/social/recommended-people.
///
/// Distinct from `SocialFriendSuggestion`, which is ranked purely by mutual
/// friends and therefore has nothing to say to anyone who has not made a friend
/// yet — the position almost every account is in. This is ranked by how much two
/// people's listening actually resembles each other's, so it works from someone's
/// first few tracks.
struct RecommendedPerson: Decodable, Identifiable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    /// 0-100. Low is not necessarily "you two are unalike" — see `confidence`.
    let score: Int
    /// How much of the score came from the two libraries SOUNDING alike rather
    /// than sharing artist names. Nil when either side has no measured
    /// fingerprint yet.
    let sonicScore: Int?
    let mutualFriendCount: Int
    /// Plain-language reasons. The server decides what may appear here: a shared
    /// artist is only ever named when that person has opted into sharing their
    /// listening activity, so this can say "2 artists in common" where it may not
    /// say which two.
    let reasons: [String]
    /// Empty unless that person opted into sharing listening activity — the
    /// server withholds the names rather than trusting the client to hide them.
    let sharedArtists: [String]
    let sharedGenres: [String]
    /// "low" / "medium" / "high" — how much listening the thinner of the two
    /// profiles actually has behind it. Lets the UI distinguish a weak match from
    /// a match it simply cannot judge yet, which a bare percentage cannot.
    let confidence: String

    var id: String { userId }

    var isLowConfidence: Bool { confidence == "low" }

    enum CodingKeys: String, CodingKey {
        case userId            = "user_id"
        case username
        case displayName       = "display_name"
        case avatarURL         = "avatar_url"
        case score
        case sonicScore        = "sonic_score"
        case mutualFriendCount = "mutual_friend_count"
        case reasons
        case sharedArtists     = "shared_artists"
        case sharedGenres      = "shared_genres"
        case confidence
    }
}

/// Why `GET /api/social/recommended-people` returned nobody. The three cases
/// need different things said to the user, and an empty list says none of them.
enum RecommendedPeopleEmptyReason: String, Decodable {
    case notEnoughListeningHistory = "not_enough_listening_history"
    case noSimilarListenersYet     = "no_similar_listeners_yet"
    case noCandidates              = "no_candidates"

    var message: String {
        switch self {
        case .notEnoughListeningHistory:
            return "Play a few more tracks and we'll find people who listen like you."
        case .noSimilarListenersYet:
            return "No one matches your taste yet — check back as more people join."
        case .noCandidates:
            return "You're already connected to everyone we could suggest."
        }
    }
}

/// One entry from GET /api/social/friends/suggestions.
struct SocialFriendSuggestion: Decodable, Identifiable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    let mutualFriendCount: Int

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId            = "user_id"
        case username
        case displayName       = "display_name"
        case avatarURL         = "avatar_url"
        case mutualFriendCount = "mutual_friend_count"
    }
}

/// Presence for one user — GET /api/social/presence/{user_id} or one entry
/// of the batched GET /api/social/presence/friends response.
struct SocialPresence: Decodable, Identifiable, Equatable {
    let userId: String
    let online: Bool
    let isPlaying: Bool
    let nowPlayingTitle: String?
    let nowPlayingArtist: String?
    /// Remote thumbnail URL for the currently-playing track, when the
    /// reporting device could cheaply derive one (see
    /// PresenceService.sendHeartbeat) — `nil` for purely-local imports or
    /// while nothing's playing, same as the title/artist fields.
    let nowPlayingArtworkURL: String?
    let lastSeenAt: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId              = "user_id"
        case online
        case isPlaying           = "is_playing"
        case nowPlayingTitle     = "now_playing_title"
        case nowPlayingArtist    = "now_playing_artist"
        case nowPlayingArtworkURL = "now_playing_artwork_url"
        case lastSeenAt          = "last_seen_at"
    }
}

/// Response from GET /api/social/presence/friends.
struct SocialFriendsPresenceResponse: Decodable {
    let presence: [SocialPresence]
}

/// One entry from GET /api/social/activity/friends — extra feature #1,
/// a friends-only feed of recent plays/favorites.
struct SocialActivityEntry: Decodable, Identifiable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    let kind: String   // "played" or "favorited"
    let title: String?
    let artist: String?
    let at: String?

    var id: String { "\(userId)-\(kind)-\(at ?? "")-\(title ?? "")" }

    var isPlayed: Bool { kind == "played" }

    var date: Date? {
        guard let at else { return nil }
        return parseServerDate(at)
    }

    enum CodingKeys: String, CodingKey {
        case userId      = "user_id"
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
        case kind, title, artist, at
    }
}

/// One entry from GET /api/social/profile/{user_id}/comments — a short
/// guestbook-style message a friend left on a profile.
struct ProfileComment: Decodable, Identifiable, Equatable {
    let id: String
    let authorUserId: String
    let authorUsername: String
    let authorDisplayName: String?
    let authorAvatarURL: String?
    let body: String
    let createdAt: String?

    var date: Date? {
        guard let createdAt else { return nil }
        return parseServerDate(createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case authorUserId      = "author_user_id"
        case authorUsername    = "author_username"
        case authorDisplayName = "author_display_name"
        case authorAvatarURL   = "author_avatar_url"
        case body
        case createdAt         = "created_at"
    }
}

/// Response from GET /api/social/profile/{user_id}/comments.
struct ProfileCommentsResponse: Decodable {
    let comments: [ProfileComment]
}

/// Response from GET /api/social/compatibility/{user_id} — a "Music Match"
/// score between the caller and a friend, derived from shared top/favorited
/// artists and library genre overlap (see the bridge's
/// `_taste_display_map_and_keys`/`_jaccard`; artists weighted 70%, genres 30%).
struct MusicCompatibility: Decodable, Equatable {
    let score: Int
    let insufficientData: Bool
    let sharedArtists: [String]
    let sharedGenres: [String]
    /// How much of the match came from the two libraries actually SOUNDING
    /// alike, rather than sharing artist names. Nil when either side has too
    /// little analysed music to have a shape yet.
    ///
    /// Name overlap alone had a hard failure in it: two people whose taste is
    /// genuinely alike but who own no artist in common scored exactly zero,
    /// because a set intersection can only see labels it can string-match.
    let sonicScore: Int?
    /// Plain-language reasons for the score. A bare percentage cannot be agreed
    /// or disagreed with; "you both lean fast and bright" can.
    let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case score
        case insufficientData = "insufficient_data"
        case sharedArtists     = "shared_artists"
        case sharedGenres      = "shared_genres"
        case sonicScore        = "sonic_score"
        case reasons
    }

    // Both new fields tolerate absence so an older bridge still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decode(Int.self, forKey: .score)
        insufficientData = (try? c.decode(Bool.self, forKey: .insufficientData)) ?? false
        sharedArtists = (try? c.decode([String].self, forKey: .sharedArtists)) ?? []
        sharedGenres = (try? c.decode([String].self, forKey: .sharedGenres)) ?? []
        sonicScore = try? c.decodeIfPresent(Int.self, forKey: .sonicScore)
        reasons = (try? c.decode([String].self, forKey: .reasons)) ?? []
    }
}

// MARK: - Sonic fingerprint

/// What a library actually sounds like — GET /api/social/fingerprint/{id}.
///
/// Derived from the tempo and tonal measurements the server already makes for
/// Auto EQ and Smart Crossfade, so it describes real listening rather than
/// self-reported taste. Visible for yourself and for friends only: a library's
/// shape says what someone actually listens to rather than what they chose to
/// display, so it follows Music Match's rule rather than the public profile's.
struct SonicFingerprint: Decodable, Equatable {
    let available: Bool
    let trackCount: Int?
    let medianBPM: Double?
    let bpmSpread: Double?
    /// Ten values in `bandHz` order, dB relative to each track's own level.
    let spectrum: [Double]?
    let bandHz: [Int]?
    /// One-line human summary, e.g. "mid-paced and consistent — around 103 bpm".
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case available, spectrum, summary
        case trackCount = "track_count"
        case medianBPM  = "median_bpm"
        case bpmSpread  = "bpm_spread"
        case bandHz     = "band_hz"
    }
}

// MARK: - Friends tab expansion models (2026-07-21)

/// Response from GET /api/social/friends/tags — the caller's own distinct
/// tag names across all friends, used to populate the filter-chip row above
/// the redesigned friends list.
struct FriendTagNamesResponse: Decodable {
    let tags: [String]
}

/// One entry from GET /api/social/friends/leaderboard — extra feature: a
/// weekly "most active friend" ranking by play count.
struct FriendLeaderboardEntry: Decodable, Identifiable, Equatable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    let playCount: Int

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId      = "user_id"
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
        case playCount   = "play_count"
    }
}

/// Response from GET /api/social/friends/leaderboard.
struct FriendLeaderboardResponse: Decodable {
    let leaderboard: [FriendLeaderboardEntry]
}

/// Response from GET /api/social/presence/listening-together — extra
/// feature: which friends are playing the exact same track as the caller
/// right now.
struct ListeningTogetherResponse: Decodable {
    let title: String?
    let artist: String?
    let listeningTogether: [SocialUserRef]

    enum CodingKeys: String, CodingKey {
        case title, artist
        case listeningTogether = "listening_together"
    }
}

// MARK: - Feature: profile-customization-3 (2026-07-21)
//
// Five more profile/social-profile features on top of everything above:
// profile visitor stats, a listening streak stat, milestone badges, a
// featured/spotlight playlist, and a friends-only "recently played
// together" overlap card. All wire into the existing MySocialProfile /
// PublicSocialProfile payloads above except the last two, which are their
// own small request/response types below.

/// Current/longest consecutive-day listening streaks — GET
/// /api/social/profile/me's `listening_streak` (always present) or
/// /api/social/profile/{user_id}'s (present only when the owner opted in
/// via `show_listening_stats`).
struct ListeningStreak: Decodable, Equatable {
    let currentStreakDays: Int
    let longestStreakDays: Int

    enum CodingKeys: String, CodingKey {
        case currentStreakDays = "current_streak_days"
        case longestStreakDays = "longest_streak_days"
    }
}

/// One milestone achievement chip (e.g. "1 Year+", "500 Plays") — always
/// present on both /me and public profiles, no privacy toggle; see the
/// bridge's `_compute_profile_badges`. `icon` is an SF Symbol name; `tier`
/// is one of "bronze"/"silver"/"gold".
struct ProfileBadge: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let label: String
    let icon: String
    let tier: String
}

/// One friend who's recently visited a profile — only ever populated when
/// the viewer is a friend of the profile owner (see `_profile_visitor_stats`).
struct ProfileVisitor: Decodable, Identifiable, Equatable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    let lastViewedAt: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId       = "user_id"
        case username
        case displayName  = "display_name"
        case avatarURL    = "avatar_url"
        case lastViewedAt = "last_viewed_at"
    }
}

/// One track preview line inside a `FeaturedPlaylist`.
struct FeaturedPlaylistTrackPreview: Decodable, Equatable {
    let title: String
    let artist: String?
}

/// An owner-chosen spotlight playlist shown on their profile — `nil` on
/// both MySocialProfile/PublicSocialProfile when nothing is featured (or,
/// for a public profile, when the featured playlist has since been
/// deleted — see the bridge's `_featured_playlist_payload`).
struct FeaturedPlaylist: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let trackCount: Int
    let previewTracks: [FeaturedPlaylistTrackPreview]

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case trackCount    = "track_count"
        case previewTracks = "preview_tracks"
    }
}

/// A minimal summary of one of the caller's own server-stored playlists —
/// GET /user/playlists returns full per-playlist track lists (needed
/// elsewhere for collaborative-playlist sync), but the Featured Playlist
/// picker only needs id/name/track count, so this intentionally never
/// decodes the "tracks" array's individual track fields, just its length.
struct RemotePlaylistSummary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let trackCount: Int

    private enum CodingKeys: String, CodingKey { case id, name, tracks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        trackCount = (try container.decodeIfPresent([_EmptyDecodableStub].self, forKey: .tracks) ?? []).count
    }
}

/// A `Decodable` with no stored properties — decoding an array of these
/// against an array of real track JSON objects still succeeds (extra keys
/// are simply ignored), so this is a zero-allocation-of-fields way to learn
/// just an array's *length* without paying to decode every track's fields.
private struct _EmptyDecodableStub: Decodable {}

/// One track from GET /api/social/profile/{user_id}/recently-played-together
/// — extra feature #5: tracks both the caller and a friend have played in
/// the last 30 days, newest shared listen first.
struct SharedRecentTrack: Decodable, Identifiable, Equatable {
    let title: String
    let artist: String?
    let yourLastPlayedAt: String?
    let theirLastPlayedAt: String?

    var id: String { "\(title)-\(artist ?? "")" }

    var mostRecentDate: Date? {
        let candidates = [yourLastPlayedAt, theirLastPlayedAt].compactMap { $0 }.compactMap(parseServerDate)
        return candidates.max()
    }

    enum CodingKeys: String, CodingKey {
        case title, artist
        case yourLastPlayedAt  = "your_last_played_at"
        case theirLastPlayedAt = "their_last_played_at"
    }
}

/// Response from GET /api/social/profile/{user_id}/recently-played-together.
struct SharedRecentTracksResponse: Decodable {
    let tracks: [SharedRecentTrack]
}
