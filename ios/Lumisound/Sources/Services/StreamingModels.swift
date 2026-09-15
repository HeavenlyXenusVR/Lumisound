import Foundation

// MARK: - StreamTrack

struct StreamTrack: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let durationSeconds: Int
    let thumbnailURL: String
    let source: String       // "youtube", "soundcloud", or "bandcamp"
    let youtubeURL: String   // canonical URL for sharing

    var duration: TimeInterval { TimeInterval(durationSeconds) }

    /// The `LUMISOUND_ID`-style identifier embedded in downloaded files'
    /// metadata (see `_estimate_bpm`/download tagging in the bridge), used to
    /// match this search result against an already-downloaded `Song` by
    /// `Song.sourceTrackID` regardless of filename/title differences.
    var sourceTrackID: String { "\(source):\(id)" }

    var durationText: String {
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    // MARK: Codable keys (bridge returns snake_case)

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case durationSeconds = "duration_seconds"
        case thumbnailURL    = "thumbnail_url"
        case source
        case youtubeURL      = "youtube_url"
    }
}

// MARK: - UserMusicTrack  (personal server library, per-user)

struct UserMusicTrack: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let genre: String
    let trackNumber: String
    let hasArtwork: Bool
    let serverPath: String   // relative to the user's personal music dir
    let filename: String
    let ext: String          // the REAL container extension — already unwrapped
                              // server-side for a locked track (e.g. "opus" for
                              // "Song.opus.lms"), never "lms" itself.
    /// True for a Lumisound-locked (`.lms`) cloud backup of a track converted
    /// by the native app's `LumisoundExclusiveExtensionService` — its bytes
    /// on the server are XOR-masked, not directly decodable audio, until
    /// unlocked with `LumisoundLockFormat` (see that type's header comment).
    /// `toSong(userMusicTrack:token:)` downloads+unlocks these before
    /// playback instead of streaming the raw URL.
    let isLocked: Bool
    /// Server-measured tempo — including for locked tracks, which this device
    /// cannot analyse without downloading and unlocking them first.
    var bpm: Double? = nil
    /// How the track ends and begins — see TransitionProfile. All optional:
    /// they are nil until the server's backfill has reached the track, and an
    /// older bridge does not send them at all.
    var trailingSilenceS: Double? = nil
    var outroSlopeDB: Double? = nil
    var outroColdStop: Bool? = nil
    var introLeadInS: Double? = nil
    var introOnsetHardness: Double? = nil
    /// Ten-band tonal fingerprint driving Auto EQ — see SpectralEQMatcher.
    var spectralProfile: [Double]? = nil

    var durationText: String {
        let s = Int(duration)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// Nil until the server has profiled this track, in which case Smart
    /// Crossfade falls back to its own live level reading.
    var transitionProfile: TransitionProfile? {
        guard trailingSilenceS != nil || outroSlopeDB != nil || introLeadInS != nil else { return nil }
        return TransitionProfile(
            trailingSilence: trailingSilenceS ?? 0,
            outroSlopeDB: outroSlopeDB ?? 0,
            outroColdStop: outroColdStop ?? false,
            introLeadIn: introLeadInS ?? 0,
            introOnsetHardness: introOnsetHardness ?? 0
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, genre
        case trackNumber = "track_number"
        case hasArtwork  = "has_artwork"
        case serverPath  = "server_path"
        case filename, ext
        case isLocked    = "is_locked"
        case bpm
        case trailingSilenceS   = "trailing_silence_s"
        case outroSlopeDB       = "outro_slope_db"
        case outroColdStop      = "outro_cold_stop"
        case introLeadInS       = "intro_lead_in_s"
        case introOnsetHardness = "intro_onset_hardness"
        case spectralProfile    = "spectral_profile"
    }
}

// MARK: - WeeklyMixTrack  (GET /user/music/weekly-mix)

/// One track from the user's personalized weekly mix — server-generated
/// (see `_generate_weekly_mix_core`/`_weekly_mix_loop` in main.py) from the
/// user's own uploaded personal library (`ios_user_music_metadata`), biased
/// toward artists they've actually played recently. `relativePath` is what
/// `weeklyMixStreamURL(for:)` needs to actually play it — the bridge only
/// ever returns rows where that's non-null, so every track this decodes to
/// is guaranteed playable.
struct WeeklyMixTrack: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let bpm: Double?
    let musicalKey: String?
    let relativePath: String
    let hasArtwork: Bool

    enum CodingKeys: String, CodingKey {
        case id           = "metadata_id"
        case title, artist, album, bpm
        case musicalKey   = "musical_key"
        case relativePath = "relative_path"
        case hasArtwork   = "has_artwork"
    }
}

// MARK: - StorageUsage  (personal cloud library storage/quota, GET /user/storage/usage)

/// Cloud storage usage/quota for the logged-in user's Personal Cloud Library
/// (uploaded music + gallery background images). `quotaBytes == 0` means
/// unlimited — the server admin hasn't set a cap, either server-wide or for
/// this specific account.
struct StorageUsage: Decodable, Equatable {
    let musicBytes: Int
    let musicCount: Int
    let galleryBytes: Int
    let usedBytes: Int
    let quotaBytes: Int
    let quotaExceeded: Bool

    var isUnlimited: Bool { quotaBytes == 0 }

    /// 0...1, clamped — nil when unlimited (there's nothing to show a fraction of).
    var usedFraction: Double? {
        guard !isUnlimited, quotaBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(quotaBytes)))
    }

    enum CodingKeys: String, CodingKey {
        case musicBytes    = "music_bytes"
        case musicCount    = "music_count"
        case galleryBytes  = "gallery_bytes"
        case usedBytes     = "used_bytes"
        case quotaBytes    = "quota_bytes"
        case quotaExceeded = "quota_exceeded"
    }
}

// MARK: - DownloadHistoryTrack  (server-side record of past /api/download calls)

/// A track this account has downloaded before, as recorded server-side by
/// `/api/download` and returned by `/user/download-history`. Used to surface
/// "My Library" search results for tracks the user has ever downloaded (even
/// if no longer present on this device) and to power a "previously
/// downloaded" restore list.
struct DownloadHistoryTrack: Identifiable, Codable, Hashable {
    let source: String
    let id: String
    let title: String
    let artist: String
    let thumbnailURL: String
    let durationSeconds: Int
    let format: String
    let downloadCount: Int
    let lastDownloadedAt: String?

    var sourceTrackID: String { "\(source):\(id)" }

    /// Converts to a `StreamTrack` so it can be downloaded/played via the
    /// same pipeline as search results.
    var asStreamTrack: StreamTrack {
        let youtubeURL = source == "youtube" ? "https://youtube.com/watch?v=\(id)" : ""
        return StreamTrack(
            id: id,
            title: title,
            artist: artist,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL,
            source: source,
            youtubeURL: youtubeURL
        )
    }

    enum CodingKeys: String, CodingKey {
        case source, id, title, artist
        case thumbnailURL = "thumbnail_url"
        case durationSeconds = "duration_seconds"
        case format
        case downloadCount = "download_count"
        case lastDownloadedAt = "last_downloaded_at"
    }
}

// MARK: - TrackMetadata  (client-provided metadata for upload)

struct TrackMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var durationSeconds: Double?
    var bitrate: Int?
    var sampleRate: Int?
    /// Whether the file being uploaded has embedded artwork — the server
    /// can't determine this itself for a Lumisound-locked (`.lms`) upload
    /// (its bytes are XOR-masked; see LumisoundLockFormat), so this is the
    /// only source of truth for those. `nil`/`false` are equivalent to the
    /// server (both mean "don't claim artwork"), kept Optional here just so
    /// call sites that haven't checked can omit it rather than assert `false`.
    var hasArtwork: Bool?
}

// MARK: - UserMusicMetadataTrack  (rich metadata from /user/music/metadata)

struct UserMusicMetadataTrack: Identifiable, Codable, Hashable {
    let id: String                     // SHA-256 of file content
    let filename: String
    let originalFilename: String?
    let title: String?
    let artist: String?
    let album: String?
    let genre: String?
    let year: String?
    let durationSeconds: Double?
    let fileSizeBytes: Int?
    let bitrate: Int?
    let sampleRate: Int?
    let mimeType: String?
    let hasArtwork: Bool
    let uploadedAt: String?
    let artworkURL: String?
    /// Server-computed tempo/key/loudness (see `_estimate_bpm`/`_estimate_key`/
    /// `_measure_loudness` in ios-bridge), populated at upload time and via
    /// `/user/music/metadata/backfill` for older uploads. `gainDb` is the
    /// dB offset to reach the standard loudness target — see `_loudness_gain_db`.
    /// These were previously fetched then silently dropped (missing from
    /// CodingKeys); fixed 2026-07-04.
    let bpm: Double?
    let musicalKey: String?
    let loudnessLufs: Double?
    let gainDb: Double?

    enum CodingKeys: String, CodingKey {
        case id, filename, title, artist, album, genre, year, bpm
        case originalFilename = "original_filename"
        case durationSeconds  = "duration_seconds"
        case fileSizeBytes    = "file_size_bytes"
        case bitrate
        case sampleRate       = "sample_rate"
        case mimeType         = "mime_type"
        case hasArtwork       = "has_artwork"
        case uploadedAt       = "uploaded_at"
        case artworkURL       = "artwork_url"
        case musicalKey       = "musical_key"
        case loudnessLufs     = "loudness_lufs"
        case gainDb           = "gain_db"
    }

    var durationText: String {
        guard let d = durationSeconds else { return "--:--" }
        let s = Int(d)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    var fileSizeText: String {
        guard let bytes = fileSizeBytes else { return "" }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    /// e.g. "128 BPM · A minor" — nil if the server hasn't analyzed this
    /// track yet (older uploads, before /user/music/metadata/backfill runs).
    var tempoKeyText: String? {
        var parts: [String] = []
        if let bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        if let musicalKey, !musicalKey.isEmpty { parts.append(musicalKey) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - RecommendationsResponse  (harmonic-mixing suggestions from /user/music/recommendations)

struct RecommendationsResponse: Decodable {
    let seedBpm: Double?
    let seedKey: String?
    let tracks: [RecommendedTrack]

    enum CodingKeys: String, CodingKey {
        case seedBpm = "seed_bpm"
        case seedKey = "seed_key"
        case tracks
    }
}

struct RecommendedTrack: Identifiable, Decodable {
    let id: String
    let filename: String
    let title: String?
    let artist: String?
    let album: String?
    let bpm: Double?
    let musicalKey: String?
    let keyCompatible: Bool
    let bpmRatio: Double?

    enum CodingKeys: String, CodingKey {
        case id, filename, title, artist, album, bpm
        case musicalKey   = "musical_key"
        case keyCompatible = "key_compatible"
        case bpmRatio     = "bpm_ratio"
    }

    /// e.g. "124 BPM · A minor"
    var tempoKeyText: String {
        var parts: [String] = []
        if let bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        if let musicalKey, !musicalKey.isEmpty { parts.append(musicalKey) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - GalleryImageInfo  (cloud-synced gallery image)

struct GalleryImageInfo: Identifiable, Codable, Hashable {
    let id: String
    let filename: String
    let displayOrder: Int
    let uploadedAt: String?
    let url: String         // relative path on bridge, e.g. /user/gallery/images/{id}

    enum CodingKeys: String, CodingKey {
        case id, filename, url
        case displayOrder = "display_order"
        case uploadedAt   = "uploaded_at"
    }
}

// MARK: - ServerTrack

struct ServerTrack: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let genre: String
    let trackNumber: String
    let hasArtwork: Bool
    let serverPath: String
    let filename: String
    let ext: String

    var durationText: String {
        let s = Int(duration)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, genre
        case trackNumber = "track_number"
        case hasArtwork  = "has_artwork"
        case serverPath  = "server_path"
        case filename, ext
    }
}

// MARK: - StreamResponse helpers

/// One entry from GET /api/search/suggestions or /api/search/trending.
struct SearchQueryCount: Identifiable, Codable, Hashable {
    let query: String
    let count: Int
    var id: String { query }
}

private struct StreamResponse: Decodable {
    let url: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case url
        case expiresIn = "expires_in"
    }
}

