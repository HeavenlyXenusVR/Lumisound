import SwiftUI

// MARK: - TVLibraryView (per-user cloud library)

struct TVLibraryView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    private enum Mode: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        case genres = "Genres"
        case favorites = "Favorites"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .songs: return "music.note"
            case .albums: return "square.stack"
            case .artists: return "music.mic"
            case .genres: return "guitars"
            case .favorites: return "star.fill"
            }
        }
    }
    @State private var mode: Mode = .songs
    @State private var searchText = ""

    /// Local, in-memory filter over the already-loaded library — cheaper and
    /// far more responsive than re-hitting `/user/music` per keystroke,
    /// which does a full filesystem walk + ffprobe pass on every request.
    /// Only the Songs tab is filtered by it; Albums/Artists/Genres still
    /// group the whole library so browsing by those dimensions isn't
    /// truncated by an unrelated in-progress search.
    ///
    /// Cached rather than a plain computed property: with a several-
    /// thousand-track library this `.filter`/`.compactMap` pair (`queue`
    /// chains directly off it) re-ran on EVERY `body` evaluation — not just
    /// per keystroke, but on every unrelated re-render too (mode switches,
    /// favorite toggles, `client` publishing anything) — since a computed
    /// property has no memory of whether its inputs actually changed. Same
    /// class of fix as `TVAlbumsGridView.cachedAlbums`.
    @State private var filteredSongs: [UserMusicTrack] = []
    @State private var queue: [TVPlayable] = []
    @State private var filterDebounceTask: Task<Void, Never>?

    private func recomputeFilteredSongs() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let library = client.library
        let filtered = q.isEmpty ? library : library.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q)
        }
        filteredSongs = filtered
        queue = filtered.compactMap { client.playable(from: $0, token: token) }
    }

    /// Debounced for `searchText` (fires once per pause in typing, not once
    /// per keystroke); immediate for the library actually loading/changing.
    private func scheduleFilterRecompute() {
        filterDebounceTask?.cancel()
        filterDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            recomputeFilteredSongs()
        }
    }

    /// Count line beside the screen title — the only place the library's size
    /// is stated, and a cheap sanity check that a sync actually happened.
    private var libraryDetail: String? {
        guard !client.library.isEmpty else { return nil }
        let n = client.library.count
        let shown = filteredSongs.count
        if shown != n && !searchText.isEmpty { return "\(shown) of \(n) tracks" }
        return "\(n) track\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !client.isLoadingLibrary && client.libraryError == nil && !client.library.isEmpty {
                TVScreenTitle(title: "Library", detail: libraryDetail)
                    .padding(.bottom, 24)
                modeChips
                    .padding(.bottom, 26)
            }

            Group {
                if client.isLoadingLibrary {
                    ProgressView("Loading your library…").padding(.top, 100)
                } else if let err = client.libraryError {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.icloud").font(.system(size: 70)).foregroundStyle(.secondary)
                        Text(err).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { Task { await client.fetchLibrary(token: token) } }
                            .frame(width: 260)
                    }
                    .padding(.top, 100)
                } else if client.library.isEmpty {
                    message("Your cloud library is empty.\nAdd music from the iPhone app.",
                            systemImage: "music.note.list")
                } else {
                    switch mode {
                    case .songs: songsList
                    case .albums: TVAlbumsGridView(client: client, token: token, library: client.library)
                    case .artists: TVArtistsGridView(client: client, token: token, library: client.library)
                    case .genres: TVGenresGridView(client: client, token: token, library: client.library)
                    case .favorites: TVFavoritesGridView(client: client, token: token)
                    }
                }
            }
        }
        .tvAmbientBackground()
        .searchable(text: $searchText, prompt: "Search your library")
        .task {
            if client.library.isEmpty { await client.fetchLibrary(token: token) }
            if client.favoriteSongIDs.isEmpty { await client.fetchFavorites(token: token) }
            recomputeFilteredSongs()
        }
        .onChange(of: searchText) { _ in scheduleFilterRecompute() }
        .onChange(of: client.library.count) { _ in recomputeFilteredSongs() }
    }

    /// Custom chip row replacing the stock segmented `Picker` — matches the
    /// filter/pill visual language used across the rest of the redesign
    /// instead of a plain system control.
    private var modeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(Mode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        TVChip(title: m.rawValue, isSelected: mode == m, systemImage: m.systemImage)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, TVMetrics.margin)
        }
    }

    /// Songs as a dense list rather than a grid of covers — see `TVTrackRow`
    /// for why. `.buttonStyle(.plain)`, not `.card`: the system card style
    /// applies its own lift-and-shadow treatment sized for square artwork,
    /// which on a full-width row reads as the whole screen jumping. The row
    /// draws its own focus state instead.
    private var songsList: some View {
        ScrollView {
            if filteredSongs.isEmpty {
                Text("No songs match “\(searchText)”.")
                    .font(.title3).foregroundStyle(.secondary).padding(.top, 100)
            } else {
                LazyVStack(spacing: TVMetrics.row) {
                    ForEach(filteredSongs) { track in
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
                .padding(.horizontal, TVMetrics.margin)
                .padding(.top, 8)
                // Clears the mini-player bar pinned to the bottom of the shell,
                // so the last row can still be focused and read.
                .padding(.bottom, 150)
            }
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage).font(.system(size: 70)).foregroundStyle(.secondary)
            Text(text).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 120)
    }
}
