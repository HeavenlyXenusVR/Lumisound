import SwiftUI

// MARK: - Grouping (mirrors LibraryManager's album/artist derivation on iOS:
// group by the metadata field verbatim — case-insensitive alphabetical order
// — falling back to "Unknown Album"/"Unknown Artist" for tracks with no tag.
// Note: the bridge itself already falls back to the containing folder name
// for `album` when a file has no album tag (see `/user/music` in
// ios-bridge/main.py), so grouping by `album` here also surfaces
// folder-organized uploads without needing a separate "folder" tab.)

struct TVAlbumGroup: Identifiable, Hashable {
    let name: String
    let tracks: [UserMusicTrack]  // always non-empty — built via Dictionary(grouping:)
    var id: String { name }
    var representativeTrack: UserMusicTrack { tracks[0] }
    var artistName: String {
        let a = tracks[0].artist
        return a.isEmpty ? "Unknown Artist" : a
    }
}

struct TVArtistGroup: Identifiable, Hashable {
    let name: String
    let tracks: [UserMusicTrack]
    var id: String { name }
    var albumCount: Int { Set(tracks.map { $0.album.isEmpty ? "Unknown Album" : $0.album }).count }
}

struct TVGenreGroup: Identifiable, Hashable {
    let name: String
    let tracks: [UserMusicTrack]
    var id: String { name }
}

/// Track order within an album: by track number (untagged tracks sort last),
/// then title — matches `AlbumDetailView`'s ordering on iOS.
private func albumSortKey(_ t: UserMusicTrack) -> (Int, String) {
    (Int(t.trackNumber) ?? Int.max, t.displayTitle)
}

func tvAlbumGroups(from library: [UserMusicTrack]) -> [TVAlbumGroup] {
    let groups = Dictionary(grouping: library) { $0.album.isEmpty ? "Unknown Album" : $0.album }
    return groups.keys
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        .map { name in
            TVAlbumGroup(name: name, tracks: (groups[name] ?? []).sorted {
                let (n0, t0) = albumSortKey($0), (n1, t1) = albumSortKey($1)
                return n0 != n1 ? n0 < n1 : t0.localizedCaseInsensitiveCompare(t1) == .orderedAscending
            })
        }
}

func tvArtistGroups(from library: [UserMusicTrack]) -> [TVArtistGroup] {
    let groups = Dictionary(grouping: library) { $0.artist.isEmpty ? "Unknown Artist" : $0.artist }
    return groups.keys
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        .map { name in
            TVArtistGroup(name: name, tracks: (groups[name] ?? []).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            })
        }
}

/// Tracks with no genre tag are omitted entirely (rather than grouped under
/// "Unknown Genre") — unlike album/artist, most uploads simply won't have a
/// genre tag, so an "Unknown Genre" bucket would just become a second,
/// noisier copy of the Songs tab instead of a useful browse dimension.
func tvGenreGroups(from library: [UserMusicTrack]) -> [TVGenreGroup] {
    let tagged = library.filter { !$0.genre.trimmingCharacters(in: .whitespaces).isEmpty }
    let groups = Dictionary(grouping: tagged) { $0.genre.trimmingCharacters(in: .whitespaces) }
    return groups.keys
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        .map { name in
            TVGenreGroup(name: name, tracks: (groups[name] ?? []).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            })
        }
}

// MARK: - Albums grid

struct TVAlbumsGridView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let library: [UserMusicTrack]

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 48)]

    // `tvAlbumGroups` is a `Dictionary(grouping:)` + sort over the WHOLE
    // library — with a several-thousand-track cloud library, recomputing it
    // as a plain `let` inline in `body` (as this used to do) meant paying
    // that full O(n log n) cost on every body re-evaluation, including ones
    // triggered by unrelated state elsewhere in the view tree (e.g. typing
    // in the Songs tab's search field re-renders `TVLibraryView`, which
    // reconstructs this view even while `mode == .albums` isn't showing;
    // any other `@Published` change on the shared `client` does the same).
    // Cached in `.task(id:)` instead, same fix as iOS's `SongsTab` got for
    // its identical A-Z grouping cost — see `sortedSongsCache` there.
    @State private var cachedAlbums: [TVAlbumGroup] = []

    var body: some View {
        ScrollView {
            if cachedAlbums.isEmpty {
                Text("No albums yet.").font(.title3).foregroundStyle(.secondary).padding(.top, 100)
            } else {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(cachedAlbums) { album in
                        NavigationLink {
                            TVAlbumDetailView(client: client, token: token, album: album)
                        } label: {
                            albumCard(album)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(TVMetrics.margin)
            }
        }
        .task(id: library.count) {
            let library = library
            cachedAlbums = await Task.detached(priority: .userInitiated) { tvAlbumGroups(from: library) }.value
        }
    }

    private func albumCard(_ album: TVAlbumGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TVAuthImage(url: client.userMusicArtworkURL(for: album.representativeTrack), token: token) {
                TVArtPlaceholder(systemImage: "square.stack")
            }
            .frame(width: 280, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(album.name).font(.headline).lineLimit(2, reservesSpace: true)
            Text(album.artistName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 280)
    }
}

// MARK: - Album detail

struct TVAlbumDetailView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let album: TVAlbumGroup

    private var queue: [TVPlayable] {
        album.tracks.compactMap { client.playable(from: $0, token: token) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 40) {
                    TVAuthImage(url: client.userMusicArtworkURL(for: album.representativeTrack), token: token) {
                        TVArtPlaceholder(systemImage: "square.stack", iconScale: 1.35)
                    }
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 10)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(album.name).font(.system(size: 40, weight: .bold))
                        Text(album.artistName).font(.title3).foregroundStyle(.secondary)
                        Text("\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs")")
                            .font(.title3).foregroundStyle(.secondary)
                        if let first = queue.first {
                            NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                                Label("Play Album", systemImage: "play.fill")
                            }
                            .buttonStyle(.card)
                            .padding(.top, 10)
                        }
                    }
                }

                VStack(spacing: TVMetrics.row) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                        NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                            // Numbered rather than showing the album's own
                            // cover once per track — see TVTrackRow.trackNumber.
                            TVTrackRow(
                                artworkURL: nil,
                                token: token,
                                title: track.displayTitle,
                                artist: track.artist,
                                detail: track.duration.tvDurationText,
                                isFavorite: client.isFavorite(track.id),
                                trackNumber: index + 1
                            )
                        }
                        .buttonStyle(.plain)
                        .tvTrackActions(client: client, token: token, track: track)
                    }
                }
            }
            .padding(TVMetrics.margin)
        }
        .tvAmbientBackground()
    }
}

// MARK: - Artists grid

struct TVArtistsGridView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let library: [UserMusicTrack]

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 48)]

    /// See `TVAlbumsGridView.cachedAlbums` — same fix, same reason.
    @State private var cachedArtists: [TVArtistGroup] = []

    var body: some View {
        ScrollView {
            if cachedArtists.isEmpty {
                Text("No artists yet.").font(.title3).foregroundStyle(.secondary).padding(.top, 100)
            } else {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(cachedArtists) { artist in
                        NavigationLink {
                            TVArtistDetailView(client: client, token: token, artist: artist)
                        } label: {
                            artistCard(artist)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(TVMetrics.margin)
            }
        }
        .task(id: library.count) {
            let library = library
            cachedArtists = await Task.detached(priority: .userInitiated) { tvArtistGroups(from: library) }.value
        }
    }

    private func artistCard(_ artist: TVArtistGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TVArtPlaceholder(systemImage: "music.mic", iconScale: 1.35)
                .frame(width: 280, height: 280)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(artist.name).font(.headline).lineLimit(2, reservesSpace: true)
            Text("\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums") · \(artist.tracks.count) \(artist.tracks.count == 1 ? "song" : "songs")")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 280)
    }
}

// MARK: - Artist detail (grouped by album, like ArtistDetailView on iOS)

struct TVArtistDetailView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let artist: TVArtistGroup

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 48)]

    var body: some View {
        let albums = tvAlbumGroups(from: artist.tracks)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(artist.name)
                    .font(.system(size: 40, weight: .bold))
                    .padding(.horizontal, 60)
                    .padding(.top, 40)

                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(albums) { album in
                        NavigationLink {
                            TVAlbumDetailView(client: client, token: token, album: album)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                TVAuthImage(url: client.userMusicArtworkURL(for: album.representativeTrack), token: token) {
                                    TVArtPlaceholder(systemImage: "square.stack")
                                }
                                .frame(width: 280, height: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                                Text(album.name).font(.headline).lineLimit(2, reservesSpace: true)
                                Text("\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(width: 280)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(TVMetrics.margin)
            }
        }
        .tvAmbientBackground()
    }
}

// MARK: - Genres grid

struct TVGenresGridView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let library: [UserMusicTrack]

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 48)]

    /// See `TVAlbumsGridView.cachedAlbums` — same fix, same reason.
    @State private var cachedGenres: [TVGenreGroup] = []

    var body: some View {
        ScrollView {
            if cachedGenres.isEmpty {
                Text("No genre-tagged songs yet.").font(.title3).foregroundStyle(.secondary).padding(.top, 100)
            } else {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(cachedGenres) { genre in
                        NavigationLink {
                            TVGenreDetailView(client: client, token: token, genre: genre)
                        } label: {
                            genreCard(genre)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(TVMetrics.margin)
            }
        }
        .task(id: library.count) {
            let library = library
            cachedGenres = await Task.detached(priority: .userInitiated) { tvGenreGroups(from: library) }.value
        }
    }

    private func genreCard(_ genre: TVGenreGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TVArtPlaceholder(systemImage: "guitars", iconScale: 1.15)
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(genre.name).font(.headline).lineLimit(2, reservesSpace: true)
            Text("\(genre.tracks.count) \(genre.tracks.count == 1 ? "song" : "songs")")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(width: 280)
    }
}

// MARK: - Genre detail

struct TVGenreDetailView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let genre: TVGenreGroup

    private var queue: [TVPlayable] {
        genre.tracks.compactMap { client.playable(from: $0, token: token) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(genre.name).font(.system(size: 40, weight: .bold))
                    Text("\(genre.tracks.count) \(genre.tracks.count == 1 ? "song" : "songs")")
                        .font(.title3).foregroundStyle(.secondary)
                    if let first = queue.first {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.card)
                        .padding(.top, 10)
                    }
                }

                VStack(spacing: TVMetrics.row) {
                    ForEach(genre.tracks) { track in
                        NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                            TVTrackRow(
                                artworkURL: client.userMusicArtworkURL(for: track),
                                token: token,
                                title: track.displayTitle,
                                artist: track.artist,
                                detail: track.duration.tvDurationText,
                                isFavorite: client.isFavorite(track.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .tvTrackActions(client: client, token: token, track: track)
                    }
                }
            }
            .padding(TVMetrics.margin)
        }
        .tvAmbientBackground()
    }
}

// MARK: - Favorites grid

struct TVFavoritesGridView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    /// Favorites resolved against the already-loaded library — a favorite
    /// whose track no longer exists in the cloud library (deleted since) is
    /// silently dropped rather than shown unplayable.
    private var favoriteTracks: [UserMusicTrack] {
        client.library.filter { client.favoriteSongIDs.contains($0.id) }
    }
    private var queue: [TVPlayable] {
        favoriteTracks.compactMap { client.playable(from: $0, token: token) }
    }

    var body: some View {
        ScrollView {
            if client.isLoadingFavorites && client.favoriteSongIDs.isEmpty {
                ProgressView("Loading favorites…").padding(.top, 100)
            } else if favoriteTracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "star").font(.system(size: 70)).foregroundStyle(.secondary)
                    Text("No favorites yet.\nHold select on a song to add one.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 120)
            } else {
                // Rows, matching the Songs list — favourites are songs, and the
                // same reasoning applies (see `TVTrackRow`). Every row here is
                // a favourite by definition, so the star is left off: a badge
                // on every item distinguishes nothing.
                LazyVStack(spacing: TVMetrics.row) {
                    ForEach(favoriteTracks) { track in
                        NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                            TVTrackRow(
                                artworkURL: client.userMusicArtworkURL(for: track),
                                token: token,
                                title: track.displayTitle,
                                artist: track.artist,
                                detail: track.duration.tvDurationText
                            )
                        }
                        .buttonStyle(.plain)
                        .tvTrackActions(client: client, token: token, track: track)
                    }
                }
                .padding(.horizontal, TVMetrics.margin)
                .padding(.top, 8)
                .padding(.bottom, 60)
            }
        }
        .task {
            if client.favoriteSongIDs.isEmpty { await client.fetchFavorites(token: token) }
        }
    }
}
