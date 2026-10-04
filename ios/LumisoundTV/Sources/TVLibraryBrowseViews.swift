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

    private var columns: [GridItem] { TVGridLayout.columns() }

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
        Group {
            if cachedAlbums.isEmpty {
                TVLoadingState(text: "Gathering albums…")
            } else {
                TVCardGrid(items: cachedAlbums) { album, cell in
                    NavigationLink {
                        TVAlbumDetailView(client: client, token: token, album: album)
                    } label: {
                        albumCard(album, width: cell)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .task(id: library.count) {
            let library = library
            cachedAlbums = await Task.detached(priority: .userInitiated) { tvAlbumGroups(from: library) }.value
        }
    }

    private func albumCard(_ album: TVAlbumGroup, width: CGFloat) -> some View {
        TVArtworkCardLabel(title: album.name, subtitle: album.artistName, width: width) {
            TVAuthImage(url: client.userMusicArtworkURL(for: album.representativeTrack), token: token) {
                TVGeneratedArt(seed: album.name, systemImage: "square.stack")
            }
        }
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
            VStack(alignment: .leading, spacing: 40) {
                TVDetailHeader(
                    eyebrow: "Album",
                    title: album.name,
                    subtitle: album.artistName,
                    meta: tvCollectionMeta(album.tracks)
                ) {
                    TVAuthImage(url: client.userMusicArtworkURL(for: album.representativeTrack), token: token) {
                        TVGeneratedArt(seed: album.name, systemImage: "square.stack")
                    }
                } actions: {
                    if let first = queue.first {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            TVPillLabel(title: "Play Album", systemImage: "play.fill")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }

                TVTrackList {
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
                        .focusEffectDisabled()
                        .tvTrackActions(client: client, token: token, track: track)
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .background(TVCollectionBackdrop(url: client.userMusicArtworkURL(for: album.representativeTrack), token: token))
    }
}

// MARK: - Artists grid

struct TVArtistsGridView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let library: [UserMusicTrack]

    private var columns: [GridItem] { TVGridLayout.columns() }

    /// See `TVAlbumsGridView.cachedAlbums` — same fix, same reason.
    @State private var cachedArtists: [TVArtistGroup] = []

    var body: some View {
        Group {
            if cachedArtists.isEmpty {
                TVLoadingState(text: "Gathering artists…")
            } else {
                TVCardGrid(items: cachedArtists) { artist, cell in
                    NavigationLink {
                        TVArtistDetailView(client: client, token: token, artist: artist)
                    } label: {
                        artistCard(artist, width: cell)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .task(id: library.count) {
            let library = library
            cachedArtists = await Task.detached(priority: .userInitiated) { tvArtistGroups(from: library) }.value
        }
    }

    private func artistCard(_ artist: TVArtistGroup, width: CGFloat) -> some View {
        // An artist has no artwork of its own server-side, so the first of
        // its tracks that HAS a cover stands in — the same substitution
        // every music app makes. Circular, so artists never read as albums.
        TVArtworkCardLabel(
            title: artist.name,
            subtitle: "\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums") · \(tvSongCount(artist.tracks.count))",
            width: width,
            isCircle: true
        ) {
            TVAuthImage(url: tvArtistArtworkURL(artist, client: client), token: token) {
                TVGeneratedArt(seed: artist.name, systemImage: "music.mic")
            }
        }
    }
}

/// First track with stored artwork, or nil when none of them have any.
@MainActor
func tvArtistArtworkURL(_ artist: TVArtistGroup, client: TVBridgeClient) -> URL? {
    guard let track = artist.tracks.first(where: { $0.hasArtwork }) else { return nil }
    return client.userMusicArtworkURL(for: track)
}

// MARK: - Artist detail (grouped by album, like ArtistDetailView on iOS)

struct TVArtistDetailView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let artist: TVArtistGroup

    var body: some View {
        let albums = tvAlbumGroups(from: artist.tracks)
        // The header sits ABOVE the grid rather than inside it: TVCardGrid owns
        // its own ScrollView (it has to measure the available width), and
        // nesting one scroll view inside another gives two competing scroll
        // areas and a focus path that can fall between them.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 34) {
                TVAuthImage(url: tvArtistArtworkURL(artist, client: client), token: token) {
                    TVGeneratedArt(seed: artist.name, systemImage: "music.mic")
                }
                .frame(width: 150, height: 150)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("ARTIST")
                        .font(TVType.eyebrow)
                        .tracking(2.4)
                        .foregroundStyle(TVPalette.neonAlt)
                    Text(artist.name)
                        .font(TVType.display)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(albums.count) \(albums.count == 1 ? "album" : "albums") · \(tvSongCount(artist.tracks.count))")
                        .font(TVType.meta)
                        .foregroundStyle(TVPalette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TVMetrics.margin)
            .padding(.top, 44)

            TVCardGrid(items: albums) { album, cell in
                NavigationLink {
                    TVAlbumDetailView(client: client, token: token, album: album)
                } label: {
                    TVArtworkCardLabel(title: album.name, subtitle: tvSongCount(album.tracks.count), width: cell) {
                        TVAuthImage(url: client.userMusicArtworkURL(for: album.representativeTrack), token: token) {
                            TVGeneratedArt(seed: album.name, systemImage: "square.stack")
                        }
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .background(TVCollectionBackdrop(url: tvArtistArtworkURL(artist, client: client), token: token))
    }
}

// MARK: - Genres grid

struct TVGenresGridView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let library: [UserMusicTrack]

    private var columns: [GridItem] { TVGridLayout.columns() }

    /// See `TVAlbumsGridView.cachedAlbums` — same fix, same reason.
    @State private var cachedGenres: [TVGenreGroup] = []

    var body: some View {
        Group {
            if cachedGenres.isEmpty {
                TVEmptyState(systemImage: "guitars",
                             title: "No genres yet",
                             message: "Songs appear here once they carry a genre tag.")
            } else {
                TVCardGrid(items: cachedGenres) { genre, cell in
                    NavigationLink {
                        TVGenreDetailView(client: client, token: token, genre: genre)
                    } label: {
                        TVArtworkCardLabel(title: genre.name, subtitle: tvSongCount(genre.tracks.count), width: cell) {
                            TVGeneratedArt(seed: genre.name, systemImage: "guitars", title: genre.name)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .task(id: library.count) {
            let library = library
            cachedGenres = await Task.detached(priority: .userInitiated) { tvGenreGroups(from: library) }.value
        }
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
            VStack(alignment: .leading, spacing: 40) {
                TVDetailHeader(
                    eyebrow: "Genre",
                    title: genre.name,
                    meta: tvCollectionMeta(genre.tracks)
                ) {
                    TVGeneratedArt(seed: genre.name, systemImage: "guitars")
                } actions: {
                    if let first = queue.first {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            TVPillLabel(title: "Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }

                TVTrackList {
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
                        .focusEffectDisabled()
                        .tvTrackActions(client: client, token: token, track: track)
                    }
                }
            }
            .padding(.bottom, 80)
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
                TVLoadingState(text: "Loading favorites…")
            } else if favoriteTracks.isEmpty {
                TVEmptyState(systemImage: "star",
                             title: "No favorites yet",
                             message: "Press and hold Select on any song to add it to your favorites.")
            } else {
                // Rows, matching the Songs list — favourites are songs. Every
                // row here is a favourite by definition, so the star is left
                // off: a badge on every item distinguishes nothing.
                TVTrackList {
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
                        .focusEffectDisabled()
                        .tvTrackActions(client: client, token: token, track: track)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 80)
            }
        }
        .task {
            if client.favoriteSongIDs.isEmpty { await client.fetchFavorites(token: token) }
        }
    }
}

// MARK: - Shared detail helpers

/// "12 songs · 48 min" for a set of library tracks.
func tvCollectionMeta(_ tracks: [UserMusicTrack]) -> String {
    let seconds = tracks.reduce(0) { $0 + max(0, $1.duration) }
    let minutes = Int((seconds / 60).rounded())
    let length = minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    return minutes > 0 ? "\(tvSongCount(tracks.count)) · \(length)" : tvSongCount(tracks.count)
}

/// A collection detail screen's backdrop: the collection's OWN artwork, washed
/// out over the brand floor — so opening an album takes on that album's colour
/// rather than whatever happens to be playing.
struct TVCollectionBackdrop: View {
    let url: URL?
    let token: String?

    var body: some View {
        ZStack {
            TVAmbientBackground()
            if url != nil {
                TVAuthImage(url: url, token: token) { Color.clear }
                    .scaleEffect(1.4)
                    .blur(radius: 110, opaque: false)
                    .saturation(1.4)
                    .overlay(TVPalette.ground.opacity(0.62))
                    .mask(
                        LinearGradient(colors: [.black, .black.opacity(0.4), .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
        }
        .ignoresSafeArea()
    }
}
