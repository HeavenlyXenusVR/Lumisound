import Foundation
import MediaPlayer

struct Song: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var url: URL?
    var persistentID: UInt64?
    var artworkCacheKey: String?
    var trackNumber: Int
    var year: String
    var genre: String
    var bitrate: Int
    var sampleRate: Int
    /// Stable source-derived identifier (e.g. "youtube:dQw4w9WgXcQ"), read from the
    /// `LUMISOUND_ID` metadata tag the bridge embeds in tracks downloaded via
    /// `/api/download`. Lets the duplicate finder and library recognise the same
    /// source track across re-downloads/re-imports under different filenames.
    /// `nil` for tracks without this tag (older downloads, on-device imports).
    var sourceTrackID: String?
    /// HTTP headers to include when fetching this song's URL (e.g. Authorization for user music).
    /// Not persisted across launches — tokens expire and are re-acquired on next login.
    var httpHeaders: [String: String]?

    /// Estimated tempo in beats per minute, lazily computed by `BPMAnalyzerService`
    /// and cached here so the library, "smarter" crossfade, and other tempo-aware
    /// features don't need to re-decode the file on every access. `nil` until
    /// analysis has run for this track.
    var bpm: Double?
    /// How this track ends and begins, measured server-side and delivered with
    /// the cloud library — see TransitionProfile. Nil for a track the server has
    /// not profiled (or one that only exists on this device), in which case
    /// Smart Crossfade falls back to its live level reading.
    var transitionProfile: TransitionProfile?
    /// When this track was added — `MPMediaItemPropertyDateAdded` for Apple
    /// Music library items, the file's creation date for imported/downloaded
    /// files. `nil` if neither was available. Used for the "Recently Added"
    /// smart playlist; not authoritative for anything else. Songs are
    /// re-scanned fresh each launch (see `LibraryManager`), so this is
    /// re-read from the source each time rather than persisted separately.
    var dateAdded: Date?

    /// `true` when `album` was not read from real embedded metadata but
    /// inferred from the file's immediate parent folder name (see
    /// `DocumentImportService.makeSong`'s "Artist/Album/track.mp3" heuristic).
    /// Optional (rather than defaulting to `false`) so old cached/persisted
    /// `Song` JSON without this key still decodes via Swift's synthesized
    /// `Decodable` (which uses `decodeIfPresent` for `Optional` properties) —
    /// a non-optional `Bool` here would throw on every snapshot saved before
    /// this field existed. `nil` and `false` both mean "not folder-inferred".
    ///
    /// Exists so the Albums tab can stay strictly metadata-derived: a user's
    /// own organisational folder (see `FoldersTab`/`MusicFolderService`) is a
    /// different concept from an album and must not show up as one just
    /// because an untagged file happened to sit inside it. See
    /// `groupableAlbumName` and `LibraryManager.rebuildAllSongs()`.
    var albumInferredFromFolder: Bool?

    /// How this instance ended up in the playback queue — see `QueueSource`.
    /// Only meaningful for `Song`s living in `AudioPlayerManager.queue`; a
    /// plain library/search-result `Song` just carries `nil`. Optional (rather
    /// than a non-optional property with a default) so decoding a `Song` saved
    /// before this field existed — e.g. an older `PlaybackSnapshot` blob in
    /// `AudioPlayerManager+Persistence` — never fails on a missing key:
    /// Swift's synthesized `Decodable` only defaults missing keys
    /// automatically for `Optional` properties, not ones with a plain default
    /// value (same reasoning as `AudioSettings.spatialAudioEnabled`). Read via
    /// `resolvedQueueSource` (`AudioPlayerManager+Queue.swift`), which treats
    /// `nil` as `.autoContinuation`.
    var queueSource: QueueSource?

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String = "",
        album: String = "",
        duration: TimeInterval = 0,
        url: URL? = nil,
        persistentID: UInt64? = nil,
        artworkCacheKey: String? = nil,
        trackNumber: Int = 0,
        year: String = "",
        genre: String = "",
        bitrate: Int = 0,
        sampleRate: Int = 0,
        sourceTrackID: String? = nil,
        httpHeaders: [String: String]? = nil,
        bpm: Double? = nil,
        dateAdded: Date? = nil,
        queueSource: QueueSource? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.url = url
        self.persistentID = persistentID
        self.artworkCacheKey = artworkCacheKey
        self.trackNumber = trackNumber
        self.year = year
        self.genre = genre
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.sourceTrackID = sourceTrackID
        self.httpHeaders = httpHeaders
        self.bpm = bpm
        self.dateAdded = dateAdded
        self.queueSource = queueSource
    }

    /// Key used to spot titles that don't actually identify a track — see
    /// `LibraryManager.ambiguousTitleKeys` and `displayName`.
    var ambiguityKey: String {
        "\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return url?.deletingPathExtension().lastPathComponent ?? "Unknown Title"
        }

        // A title can be present and still tell you nothing. Downloads carry
        // whatever the source embedded, and for a lot of game-soundtrack
        // uploads that's the GAME, not the track: 27 tracks in one real library
        // all embed title "Super Smash Bros. Brawl" by the same uploader, so a
        // grid of them reads as the same entry repeated over and over with the
        // actual track name ("Star Wolf", "Rainbow Road", "Corneria") surviving
        // only in the filename. 527 of 3472 tracks there share a title+artist
        // with at least one sibling.
        //
        // Only tracks that are genuinely indistinguishable get rewritten, which
        // is what makes this safe: the naive version of this fix — "the title
        // is the tail of the filename, so use the head" — is WRONG about half
        // the time, because the two orderings both occur in the wild
        // ("Menu - Super Smash Bros." wants the head, but
        // "Portal Soundtrack - You're Not A Good Person" already has the right
        // title and wants the tail). Ambiguity is the signal that holds; word
        // order isn't.
        guard AmbiguousTitleIndex.contains(ambiguityKey),
              let stem = url?.deletingPathExtension().lastPathComponent
                  .replacingOccurrences(of: ".opus", with: "")
                  .replacingOccurrences(of: ".m4a", with: ""),
              !stem.isEmpty,
              stem.caseInsensitiveCompare(trimmed) != .orderedSame
        else { return trimmed }

        // Drop the part the title already says, so "Star Wolf - Super Smash
        // Bros. Brawl" shows as "Star Wolf" rather than repeating the series.
        // If the title isn't in the filename at all, the whole stem is still
        // more informative than a title shared with 26 other tracks.
        let suffix = " - \(trimmed)"
        if stem.hasSuffix(suffix) {
            let head = String(stem.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        let prefix = "\(trimmed) - "
        if stem.hasPrefix(prefix) {
            let tail = String(stem.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { return tail }
        }
        return stem
    }

    var artistName: String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown Artist" : artist
    }

    var albumName: String {
        album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown Album" : album
    }

    /// The album name to use when *grouping/listing distinct albums* (the
    /// Albums tab grid, `LibraryManager.albums`, `songsByAlbum`) — as opposed
    /// to `albumName`, which is fine for a per-song subtitle. This bucket
    /// intentionally treats a folder-name-inferred `album` (see
    /// `albumInferredFromFolder`) the same as no album at all, so a user's own
    /// organisational folder (already a first-class concept — see
    /// `FoldersTab`/`MusicFolderService`) never shows up disguised as an
    /// album in a view that's supposed to be strictly metadata-derived.
    /// Real, tag-derived albums (the overwhelming common case) are unaffected.
    var groupableAlbumName: String {
        albumInferredFromFolder == true ? "Unknown Album" : albumName
    }

    var durationText: String {
        guard duration.isFinite, duration > 0 else { return "0:00" }
        let total = Int(duration.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

extension Song {
    init?(mediaItem: MPMediaItem) {
        guard let assetURL = mediaItem.assetURL else { return nil }
        self.init(
            id: String(mediaItem.persistentID),
            title: mediaItem.title ?? assetURL.deletingPathExtension().lastPathComponent,
            artist: mediaItem.artist ?? "",
            album: mediaItem.albumTitle ?? "",
            duration: mediaItem.playbackDuration,
            url: assetURL,
            persistentID: mediaItem.persistentID,
            artworkCacheKey: String(mediaItem.persistentID),
            trackNumber: mediaItem.albumTrackNumber,
            year: "",
            genre: mediaItem.genre ?? "",
            dateAdded: mediaItem.dateAdded
        )
    }
}
