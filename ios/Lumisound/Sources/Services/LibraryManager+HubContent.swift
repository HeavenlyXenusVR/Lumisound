import Foundation

// MARK: - Library Hub Content
//
// Query helpers backing the redesigned Library tab's "hub" landing screen
// (see `LibraryHubView`) — a dashboard of shortcuts to the user's *real*
// playlists/folders/favorites plus a few auto-generated groupings, sitting
// above the traditional Songs/Artists/Albums/... browsing tabs (still
// reachable via `LibraryTabBar`, unchanged).
//
// Everything here is a plain function, not `@Published` state — like
// `songs(byArtist:)` etc. in `LibraryManager+FavoritesAndQueries.swift`,
// callers (specifically `LibraryHubView`) snapshot these into local
// `@State` rather than recomputing on every body re-evaluation, since
// several are O(n log n) sorts over the whole library. They live on the
// plain `HubContentBuilder` value (songs + a copy of the play history), so
// the hub can build them all off the main actor.

struct HubContentBuilder {
    let songs: [Song]
    /// A copy of `PlayHistoryStore.entries`, so this can run off the main
    /// actor (the store itself is main-actor isolated).
    let history: [String: PlayHistoryEntry]

    func playCount(for songID: String) -> Int {
        history[songID]?.playCount ?? 0
    }

    func lastPlayedAt(for songID: String) -> Date? {
        history[songID]?.lastPlayedAt
    }


    /// The most recently added songs, newest first. Falls back to
    /// `.distantPast` for songs with no known `dateAdded` (streamed-only
    /// entries, etc.), which sorts them to the end rather than excluding them.
    func recentlyAddedSongs(limit: Int = 25) -> [Song] {
        songs
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// The most-played songs (via `PlayHistoryStore`), highest count first.
    /// Songs with zero recorded plays are excluded entirely — an unplayed
    /// library shouldn't render a "Most Played" shelf full of zeros.
    func mostPlayedSongs(limit: Int = 25) -> [Song] {
        songs
            .map { ($0, playCount(for: $0.id)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Favorited songs the user hasn't played in a while (or ever) — a
    /// "don't forget about these" grouping. Mirrors the rules of the
    /// auto-seeded "Forgotten Favorites" `SmartPlaylist` (see
    /// `SmartPlaylistStore.seedDefaultsIfNeeded`) but computed directly so
    /// the hub can show it even if the user deleted that smart playlist.
    func forgottenFavoriteSongs(from favoriteSongs: [Song], limit: Int = 25, staleAfterDays: Double = 60) -> [Song] {
        let cutoff = Date().addingTimeInterval(-staleAfterDays * 86400)
        return favoriteSongs
            .filter { (lastPlayedAt(for: $0.id) ?? .distantPast) < cutoff }
            .sorted {
                (lastPlayedAt(for: $0.id) ?? .distantPast)
                    < (lastPlayedAt(for: $1.id) ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Fraction (0...1) of `songs` that have at least one recorded play —
    /// used for the speed-dial tile's optional thin progress bar as a
    /// genuine "how much of this have you listened to" indicator rather
    /// than a decorative fake value.
    func listenedFraction(of songs: [Song]) -> Double? {
        guard !songs.isEmpty else { return nil }
        let played = songs.filter { playCount(for: $0.id) > 0 }.count
        return Double(played) / Double(songs.count)
    }

    /// The most recently *played* songs (via `PlayHistoryStore.lastPlayedAt`),
    /// most recent first — distinct from `recentlyAddedSongs` (file add date)
    /// and `mostPlayedSongs` (lifetime count): this is "what did I actually
    /// listen to lately," which neither of those answers. Songs never played
    /// are excluded entirely, same reasoning as `mostPlayedSongs`.
    func recentlyPlayedSongs(limit: Int = 25) -> [Song] {
        songs
            .compactMap { song -> (Song, Date)? in
                guard let lastPlayed = lastPlayedAt(for: song.id) else { return nil }
                return (song, lastPlayed)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// The library's genres ranked by song count (most-populated first),
    /// each paired with its own songs — backs the hub's Genres carousel.
    /// Genre-less songs (empty/whitespace-only tag, common for imported
    /// files without full metadata) are excluded from every bucket rather
    /// than lumped into a misleading "Unknown" genre tile.
    func genreGroups(limit: Int = 12) -> [(genre: String, songs: [Song])] {
        var buckets: [String: [Song]] = [:]
        for song in songs {
            let genre = song.genre.trimmingCharacters(in: .whitespaces)
            guard !genre.isEmpty else { continue }
            buckets[genre, default: []].append(song)
        }
        return buckets
            .map { (genre: $0.key, songs: $0.value) }
            .sorted { $0.songs.count > $1.songs.count }
            .prefix(limit)
            .map { $0 }
    }


    /// Up to 4 representative songs (with usable artwork potential) for a
    /// speed-dial tile's collage — favors songs that actually have distinct
    /// albums/artists so the 4 quadrants don't all show identical art when
    /// avoidable, but falls back to whatever's available for small
    /// playlists/folders.
    func collageSongs(from songs: [Song], limit: Int = 4) -> [Song] {
        guard songs.count > limit else { return Array(songs.prefix(limit)) }
        var seen = Set<String>()
        var picked: [Song] = []
        for song in songs {
            let key = song.groupableAlbumName
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            picked.append(song)
            if picked.count == limit { break }
        }
        if picked.count < limit {
            for song in songs where !picked.contains(where: { $0.id == song.id }) {
                picked.append(song)
                if picked.count == limit { break }
            }
        }
        return picked
    }

    // MARK: - Home Tab expansion (2026-07-20)
    //
    // Five additional query helpers backing new `LibraryHubView` sections —
    // same "plain function, snapshot into `@State` via `.task(id:)`"
    // convention as everything else in this file.

    /// The library's artists ranked by total lifetime plays across all their
    /// songs (highest first), each paired with their own songs — backs the
    /// hub's Top Artists carousel. Artists with zero recorded plays across
    /// every song are excluded entirely, same "no shelf full of zeros"
    /// reasoning as `mostPlayedSongs`. Uses the raw (untrimmed-fallback)
    /// `artist` tag rather than `artistName`'s "Unknown Artist" fallback, so
    /// genuinely tag-less songs never form a misleading "Unknown Artist" tile
    /// — mirrors `genreGroups`' identical empty-tag exclusion.
    func topArtistGroups(limit: Int = 12) -> [(artist: String, songs: [Song], playCount: Int)] {
        var buckets: [String: [Song]] = [:]
        for song in songs {
            let artist = song.artist.trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty else { continue }
            buckets[artist, default: []].append(song)
        }
        return buckets
            .map { artist, songs -> (artist: String, songs: [Song], playCount: Int) in
                let plays = songs.reduce(0) { $0 + playCount(for: $1.id) }
                return (artist: artist, songs: songs, playCount: plays)
            }
            .filter { $0.playCount > 0 }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    /// Library songs grouped by release decade (parsed from `Song.year`,
    /// same plain-numeric-string convention `SmartPlaylist`'s `.year` rule
    /// already parses via `Double(song.year...)`), newest decade first —
    /// backs the hub's Decades carousel. Songs with missing/non-numeric/
    /// out-of-range year metadata are excluded entirely rather than lumped
    /// into a misleading catch-all bucket.
    func decadeGroups(limit: Int = 10) -> [(decade: String, songs: [Song])] {
        var buckets: [Int: [Song]] = [:]
        for song in songs {
            guard let year = Int(song.year.trimmingCharacters(in: .whitespaces)),
                  (1900...2100).contains(year)
            else { continue }
            buckets[(year / 10) * 10, default: []].append(song)
        }
        return buckets.keys
            .sorted(by: >)
            .prefix(limit)
            .map { decade in (decade: "\(decade)s", songs: buckets[decade] ?? []) }
    }

    /// Unplayed songs from the single genre the user has put the most
    /// lifetime plays into — a gentle "you clearly like this genre, here's
    /// more of it you haven't gotten to yet" nudge, distinct from both
    /// `forgottenFavoriteSongs` (favorited-but-stale) and the plain
    /// `genreGroups` browse shelf (every genre, no play-count filtering).
    /// Returns an empty array until the user has actually played something
    /// with genre metadata — there's no meaningful "favorite genre" before
    /// that, so an arbitrary genre pick is avoided rather than guessed at.
    /// Shuffled (not sorted) since there's no strong "best" ordering among
    /// equally-unplayed candidates and a static order would feel stale on
    /// every visit.
    func deeperCutsSongs(limit: Int = 20) -> [Song] {
        var genrePlayCounts: [String: Int] = [:]
        var genreBuckets: [String: [Song]] = [:]
        for song in songs {
            let genre = song.genre.trimmingCharacters(in: .whitespaces)
            guard !genre.isEmpty else { continue }
            genreBuckets[genre, default: []].append(song)
            genrePlayCounts[genre, default: 0] += playCount(for: song.id)
        }
        guard let topGenre = genrePlayCounts.max(by: { $0.value < $1.value }),
              topGenre.value > 0,
              let candidates = genreBuckets[topGenre.key]
        else { return [] }
        let unplayed = candidates.filter { playCount(for: $0.id) == 0 }
        return Array(unplayed.shuffled().prefix(limit))
    }

    /// A lightweight "This Week" recap — distinct songs last played in the
    /// past 7 days, their summed duration as an estimated listening-minutes
    /// figure, and whichever artist appears most among them. Like
    /// `songsPlayedTodayCount`, this is a casual approximation (a song
    /// played 3 times this week still only counts once, and "estimated
    /// minutes" assumes each was played to completion exactly once) rather
    /// than a precise listening-time metric — `PlayHistoryStore` only keeps
    /// a lifetime count + last-played timestamp per song, not a full
    /// per-play log, so anything more exact isn't available on-device.
    /// Returns `nil` when nothing's been played in the window, so the hub
    /// section simply doesn't render rather than showing an all-zero card.
    func weeklyRecap() -> HubWeeklyRecap? {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let playedThisWeek = songs.filter { song in
            guard let lastPlayed = lastPlayedAt(for: song.id) else { return false }
            return lastPlayed >= cutoff
        }
        guard !playedThisWeek.isEmpty else { return nil }

        let totalSeconds = playedThisWeek.reduce(0.0) { $0 + $1.duration }
        var artistCounts: [String: Int] = [:]
        for song in playedThisWeek {
            artistCounts[song.artistName, default: 0] += 1
        }
        let topArtist = artistCounts.max(by: { $0.value < $1.value })?.key

        return HubWeeklyRecap(
            songsPlayed: playedThisWeek.count,
            estimatedMinutes: Int(totalSeconds / 60),
            topArtist: topArtist
        )
    }

    /// See `weeklyRecap()`.
    struct HubWeeklyRecap {
        let songsPlayed: Int
        let estimatedMinutes: Int
        let topArtist: String?
    }

    // MARK: - Snapshot

    /// Every Home shelf, computed in one go — see `snapshot(favorites:)`.
    struct Snapshot {
        var recentlyAdded: [Song] = []
        var mostPlayed: [Song] = []
        var forgottenFavorites: [Song] = []
        var recentlyPlayed: [Song] = []
        var genreGroups: [(genre: String, songs: [Song])] = []
        var topArtistGroups: [(artist: String, songs: [Song], playCount: Int)] = []
        var decadeGroups: [(decade: String, songs: [Song])] = []
        var deeperCuts: [Song] = []
        var weeklyRecap: HubWeeklyRecap?
    }

    /// All of `LibraryHubView`'s shelves. Pure — call it from a detached
    /// task so the ~9 passes over the library stay off the main thread.
    func snapshot(favorites: [Song]) -> Snapshot {
        Snapshot(
            recentlyAdded: recentlyAddedSongs(limit: 20),
            mostPlayed: mostPlayedSongs(limit: 20),
            forgottenFavorites: forgottenFavoriteSongs(from: favorites, limit: 20),
            recentlyPlayed: recentlyPlayedSongs(limit: 20),
            genreGroups: genreGroups(limit: 12),
            topArtistGroups: topArtistGroups(limit: 12),
            decadeGroups: decadeGroups(limit: 10),
            deeperCuts: deeperCutsSongs(limit: 20),
            weeklyRecap: weeklyRecap()
        )
    }
}

// MARK: - LibraryManager conveniences
//
// Main-actor entry points kept for callers that want one shelf on demand
// (e.g. ConstellationView). `LibraryHubView` instead builds every shelf at
// once off the main actor via `HubContentBuilder.snapshot`.
extension LibraryManager {
    typealias HubWeeklyRecap = HubContentBuilder.HubWeeklyRecap

    /// A builder over the current library and play history.
    var hubContent: HubContentBuilder {
        HubContentBuilder(songs: allSongs, history: PlayHistoryStore.shared.entries)
    }

    func recentlyAddedSongs(limit: Int = 25) -> [Song] { hubContent.recentlyAddedSongs(limit: limit) }
    func mostPlayedSongs(limit: Int = 25) -> [Song] { hubContent.mostPlayedSongs(limit: limit) }
    func forgottenFavoriteSongs(limit: Int = 25, staleAfterDays: Double = 60) -> [Song] {
        hubContent.forgottenFavoriteSongs(from: favoriteSongs, limit: limit, staleAfterDays: staleAfterDays)
    }
    func listenedFraction(of songs: [Song]) -> Double? { hubContent.listenedFraction(of: songs) }
    func recentlyPlayedSongs(limit: Int = 25) -> [Song] { hubContent.recentlyPlayedSongs(limit: limit) }
    func genreGroups(limit: Int = 12) -> [(genre: String, songs: [Song])] { hubContent.genreGroups(limit: limit) }
    func collageSongs(from songs: [Song], limit: Int = 4) -> [Song] { hubContent.collageSongs(from: songs, limit: limit) }
    func topArtistGroups(limit: Int = 12) -> [(artist: String, songs: [Song], playCount: Int)] {
        hubContent.topArtistGroups(limit: limit)
    }
    func decadeGroups(limit: Int = 10) -> [(decade: String, songs: [Song])] { hubContent.decadeGroups(limit: limit) }
    func deeperCutsSongs(limit: Int = 20) -> [Song] { hubContent.deeperCutsSongs(limit: limit) }
    func weeklyRecap() -> HubWeeklyRecap? { hubContent.weeklyRecap() }

    /// Walks the play history (songs actually played) rather than the whole
    /// library — this runs on every track change.
    func songsPlayedTodayCount() -> Int {
        let calendar = Calendar.current
        return PlayHistoryStore.shared.entries.reduce(into: 0) { count, item in
            guard let lastPlayed = item.value.lastPlayedAt,
                  calendar.isDateInToday(lastPlayed),
                  songsByID[item.key] != nil
            else { return }
            count += 1
        }
    }
}
