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
                    .padding(.bottom, 22)
                modeChips
                    .padding(.bottom, 10)
            }

            Group {
                if client.isLoadingLibrary {
                    TVLoadingState(text: "Loading your library…")
                } else if let err = client.libraryError {
                    TVEmptyState(systemImage: "exclamationmark.icloud",
                                 title: "Couldn't load your library",
                                 message: err) {
                        Button {
                            Task { await client.fetchLibrary(token: token) }
                        } label: {
                            TVPillLabel(title: "Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                } else if client.library.isEmpty {
                    TVEmptyState(systemImage: "music.note.list",
                                 title: "Your library is empty",
                                 message: "Add music to your Personal Cloud Library from the iPhone app and it will show up here.")
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
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // NO `.searchable` here. On tvOS that modifier does not render a compact
        // field — it lays out a full search surface, prompt plus a letter picker
        // spanning the whole width, as a sibling of this view's own content. In
        // the old single-column shell it had the screen to itself and looked
        // fine. Inside the three-column shell it drew across the content column
        // AND over the player column beside it, which is the alphabet strip
        // running over everything in the 1.9.0 screenshot.
        //
        // Search now lives behind the pill in `modeChips` and is presented as
        // its own pushed screen (`librarySearchScreen`), which is the platform's
        // actual pattern for tvOS search and gets dictation for free.
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
            HStack(spacing: 14) {
                // Leads the row: searching is a different KIND of action from
                // switching browse dimension, so it keeps the search glyph and
                // shows the live query when one is set, rather than pretending
                // to be a sixth mode.
                NavigationLink {
                    librarySearchScreen
                } label: {
                    TVChip(
                        title: searchText.isEmpty ? "Search" : searchText,
                        isSelected: !searchText.isEmpty,
                        systemImage: "magnifyingglass"
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                ForEach(Mode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        TVChip(title: m.rawValue, isSelected: mode == m, systemImage: m.systemImage)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, TVMetrics.margin)
            // Room for a focused chip's scale and shadow, which the scroll
            // view would otherwise clip.
            .padding(.vertical, 16)
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
                TVEmptyState(systemImage: "magnifyingglass",
                             title: "No matches",
                             message: "No songs match “\(searchText)”.")
            } else {
                TVTrackList {
                    ForEach(filteredSongs) { track in
                        trackRow(track)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 80)
            }
        }
    }

    /// One library row. Shared by the browse list and the search screen so the
    /// two cannot drift apart in styling or in what a select actually does.
    private func trackRow(_ track: UserMusicTrack) -> some View {
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

    /// Library search as its own pushed screen, built on the same
    /// `UISearchController` wrapper the Search tab uses — so it gets the system
    /// tvOS keyboard, and with it dictation, which `.searchable` has no
    /// supported way to offer.
    ///
    /// Pushed rather than inline: a search surface on tvOS wants the whole
    /// screen for its keyboard, and giving it one is what stops it drawing over
    /// the neighbouring columns.
    private var librarySearchScreen: some View {
        TVDictationSearch(
            text: $searchText,
            placeholder: "Search your library",
            onChange: { _ in scheduleFilterRecompute() }
        ) {
            ScrollView {
                if filteredSongs.isEmpty {
                    TVEmptyState(
                        systemImage: "magnifyingglass",
                        title: searchText.isEmpty ? "Search your library" : "No matches",
                        message: searchText.isEmpty
                            ? "Find songs by title, artist or album."
                            : "No songs match “\(searchText)”."
                    )
                } else {
                    TVTrackList {
                        ForEach(filteredSongs) { track in
                            trackRow(track)
                        }
                    }
                    .padding(.vertical, 30)
                }
            }
            // A pushed destination replaces the shell, so it draws its own
            // backdrop — unlike the root tab screens, which sit inside it.
            .tvAmbientBackground()
        }
        .ignoresSafeArea()
    }
}
