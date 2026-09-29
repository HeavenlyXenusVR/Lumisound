import SwiftUI
import MediaPlayer

// MARK: - Song sort order

/// Backs `SongsTab`'s sort-chip row — persisted via `@AppStorage` so the
/// chosen order survives relaunches, same as `library_songs_columns`.
private enum SongSortOrder: String {
    case title
    case artist
    case dateAdded
    case playCount
    case duration

    static let allCases: [SongSortOrder] = [.title, .artist, .dateAdded, .playCount, .duration]

    var label: String {
        switch self {
        case .title:     return "Title"
        case .artist:    return "Artist"
        case .dateAdded: return "Recently Added"
        case .playCount: return "Most Played"
        case .duration:  return "Duration"
        }
    }

    var icon: String {
        switch self {
        case .title:     return "textformat"
        case .artist:    return "person.fill"
        case .dateAdded: return "clock.fill"
        case .playCount: return "flame.fill"
        case .duration:  return "timer"
        }
    }
}

// MARK: - Songs Tab

struct SongsTab: View {
    let songs: [Song]
    @Binding var searchText: String
    @Binding var showAddMusic: Bool
    @Binding var isSelecting: Bool
    @Binding var selectedSongIDs: Set<String>
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager

    private func toggleSelection(_ song: Song) {
        if selectedSongIDs.contains(song.id) {
            selectedSongIDs.remove(song.id)
        } else {
            selectedSongIDs.insert(song.id)
        }
    }

    @AppStorage("library_songs_columns") private var songColumns: Int = 1
    /// Tracks whether the entrance animation has already fired for the current song list.
    @State private var didAnimateEntrance: Bool = false

    /// Persisted sort order — a horizontally-scrollable chip row (see
    /// `statsAndSortHeader`) rather than a hidden sort menu, matching the pattern
    /// Spotify's 2026 "Your Library" redesign moved to: sort/filter controls
    /// surfaced as chips directly above the list instead of buried behind a
    /// single button.
    @AppStorage("library_songs_sort") private var sortOrderRaw: String = SongSortOrder.title.rawValue
    private var sortOrder: SongSortOrder { SongSortOrder(rawValue: sortOrderRaw) ?? .title }

    /// Logic hook the active Lua theme preset can set (`hooks.pin_favorites_first`
    /// in the preset script — see `Theme/LuaThemeEngine.swift`): when on,
    /// favorited songs float to the top of whatever `sortOrder` is chosen,
    /// keeping that order stable within each of the two groups.
    @AppStorage("lua_pin_favorites_first") private var pinFavoritesFirst: Bool = false

    /// `songs`, sorted per `sortOrder` — every place `songs` used to be
    /// rendered/played/shuffled/prefetched now goes through this instead, so
    /// "Play" starts from the top of whatever order is currently showing.
    ///
    /// Backed by `sortedSongsCache` (recomputed only when a real dependency
    /// changes — see `recomputeSortedSongs`/the `.onChange` modifiers on
    /// `body`), not derived inline. This is referenced from ~8 separate
    /// places across this view's several computed subviews (the action
    /// header, both the list and grid bodies, prefetch bounds, entrance-
    /// animation triggers, …) — as a plain computed property recomputing a
    /// full O(n log n) sort (plus, with "Most Played" selected, two
    /// `PlayHistoryStore` lookups per comparison) EVERY time any of those
    /// read it, a single `body` evaluation for a several-thousand-song
    /// library was paying for the same sort many times over, on every
    /// render — including every keystroke while the search field above is
    /// focused. Caching cuts that to one recompute per actual change.
    ///
    /// `sortedSongsCache` is `nil` (not `[]`) until the first `.onAppear`
    /// populates it — falling straight back to a live compute in that gap
    /// (rather than showing an empty list) matters because the very first
    /// `body` evaluation renders the list/grid content synchronously, before
    /// any `.onAppear`/`.onChange` modifier has had a chance to run.
    private var sortedSongs: [Song] { sortedSongsCache ?? computeSortedSongs() }

    @State private var sortedSongsCache: [Song]? = nil
    @State private var recomputeDebounceTask: Task<Void, Never>?

    private func recomputeSortedSongs() {
        sortedSongsCache = computeSortedSongs()
        recomputeIndexCache()
        alphaSectionsCache = computeAlphaSections()
    }

    /// Debounced entry point for `songs` changing — used ONLY for that
    /// trigger (see the `.onChange(of: songs)` below), not the others, which
    /// are single deliberate user actions (change sort order, toggle pin-
    /// favorites) that should recompute immediately for responsiveness.
    /// `songs` itself changes once per song as the library grows/shrinks
    /// (e.g. several downloads landing within a couple seconds of each
    /// other), and this is an O(n log n) sort PLUS a full index-cache
    /// rebuild over the whole library on every single increment — undebounced,
    /// a burst repeatedly restarted that full recompute before the previous
    /// one even finished rendering, which is what "the Songs tab freaks out"
    /// during/after a batch of downloads landing turned out to be (confirmed
    /// via a screen recording's frame-diff timeline showing the same pattern
    /// as the Home hub's identical `allSongs.count`-driven storm).
    private func scheduleRecompute() {
        recomputeDebounceTask?.cancel()
        recomputeDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            recomputeSortedSongs()
        }
    }

    private func computeSortedSongs() -> [Song] {
        let base: [Song]
        switch sortOrder {
        case .title:
            base = songs.sortedByDisplayName()
        case .artist:
            base = songs.sorted { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
        case .dateAdded:
            base = songs.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .playCount:
            base = songs.sorted { PlayHistoryStore.shared.playCount(for: $0.id) > PlayHistoryStore.shared.playCount(for: $1.id) }
        case .duration:
            base = songs.sorted { $0.duration > $1.duration }
        }
        guard pinFavoritesFirst else { return base }
        // `.sorted` on a Bool key is stable in practice here since we only
        // ever compare across the two favorite/non-favorite partitions —
        // done via an explicit stable filter+filter split (not `.sorted`)
        // so the relative order within each group from `base` above is
        // preserved exactly.
        let favorites = base.filter { library.isFavorite(songID: $0.id) }
        let rest = base.filter { !library.isFavorite(songID: $0.id) }
        return favorites + rest
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: songColumns)
    }

    /// Physical pixel size to prefetch artwork thumbnails at for whichever
    /// layout (`List` rows vs. grid cells) is currently showing — must match
    /// what `ArtworkThumbnail` actually requests, or the prefetched bucket
    /// goes unread and scrolling still shows a placeholder flash.
    private var prefetchPixelSize: CGFloat {
        songColumns == 1 ? 192 : 768
    }

    /// Hero-forward header: a big blurred-artwork backdrop (drawn from
    /// whatever's currently sitting at the top of the sorted list — the
    /// screen's own visual identity shifts with sort order/library changes
    /// instead of being a fixed banner) behind the title stats, Play/Shuffle,
    /// and the sort-chip row — replaces the old plain-caption stats line +
    /// flat action bar with one unified panel.
    private var songsHeroHeader: some View {
        ZStack(alignment: .bottom) {
            HeroArtworkBackdrop(song: sortedSongs.first, height: 200)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ScreenStatChip(icon: "music.note", text: "\(songs.count) song\(songs.count == 1 ? "" : "s")")
                    ScreenStatChip(icon: "clock", text: libraryDurationText)
                }

                HStack(spacing: 12) {
                    Button {
                        player.setQueue(sortedSongs, startIndex: 0, autoplay: true)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.dynamicAccent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Button {
                        player.setQueue(sortedSongs.shuffled(), startIndex: 0, autoplay: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(AppTheme.textPrimary)
                            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                    }
                }
                .buttonStyle(PressableButtonStyle())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SongSortOrder.allCases, id: \.self) { order in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { sortOrderRaw = order.rawValue }
                            } label: {
                                Label(order.label, systemImage: order.icon)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(sortOrder == order ? .white : AppTheme.textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        sortOrder == order ? AppTheme.dynamicAccent : Color.white.opacity(0.1),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().stroke(.white.opacity(sortOrder == order ? 0 : 0.1), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    /// "18h 32m" alone — split out of the old combined stats string now that
    /// the song count has its own chip.
    private var libraryDurationText: String {
        let totalSeconds = songs.reduce(0.0) { $0 + $1.duration }
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Alphabetical sections (only meaningful for the Title/Artist sort
    /// orders — Recently Added/Most Played/Duration have no letter to index
    /// by) — shared by the sectioned list and its index rail so both are
    /// always built from the identical grouping.
    ///
    /// Backed by `alphaSectionsCache` (recomputed only in `recomputeSortedSongs`,
    /// same as `sortedSongsCache`) rather than derived live — this was a plain
    /// computed property doing its own O(n) grouping pass over the whole
    /// library, read from 4 separate call sites in `body` (`showsIndexRail`
    /// alone reads it once, plus the list content and the rail each read it
    /// again) — 4 redundant full-library regroups on EVERY body evaluation,
    /// which for `@EnvironmentObject player`-driven re-renders means on every
    /// playback position tick, not just when the song list actually changes.
    /// Confirmed via user report as the dominant Songs-tab-specific lag on an
    /// iPhone 13 with a 3,000+ song library.
    private var alphaSections: [(letter: String, songs: [Song])] { alphaSectionsCache }
    @State private var alphaSectionsCache: [(letter: String, songs: [Song])] = []

    private func computeAlphaSections() -> [(letter: String, songs: [Song])] {
        switch sortOrder {
        case .title:  return alphabeticalSections(of: sortedSongs) { $0.displayName }
        case .artist: return alphabeticalSections(of: sortedSongs) { $0.artistName }
        default:      return []
        }
    }
    private var showsIndexRail: Bool { !alphaSectionsCache.isEmpty && songColumns == 1 && sortedSongs.count > 20 }

    /// Flat song id → position in `sortedSongs`, recomputed alongside
    /// `sortedSongsCache`. The sectioned list still needs prefetch/stagger
    /// timing keyed on a song's position in the OVERALL order (not its
    /// position within just its own letter section), and re-deriving that
    /// with `sortedSongs.firstIndex(of:)` per row would be an O(n) scan for
    /// every one of n rows on every appearance — this is the O(1) lookup
    /// that avoids turning a 1,000-song library into an O(n²) render.
    @State private var songIndexCache: [String: Int] = [:]

    private func recomputeIndexCache() {
        var map: [String: Int] = [:]
        for (i, song) in sortedSongs.enumerated() { map[song.id] = i }
        songIndexCache = map
    }

    @ViewBuilder
    private func songRowContent(_ song: Song, flatIndex: Int) -> some View {
        Button {
            if isSelecting {
                toggleSelection(song)
            } else {
                player.play(song: song, in: sortedSongs)
            }
        } label: {
            HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: selectedSongIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            selectedSongIDs.contains(song.id)
                                ? AppTheme.dynamicAccent
                                : AppTheme.textSecondary
                        )
                        .transition(.scale.combined(with: .opacity))
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: selectedSongIDs)
                }
                SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
            }
            .animation(.easeInOut(duration: 0.15), value: isSelecting)
        }
        .buttonStyle(.plain)
        .listRowBackground(AppTheme.surface.opacity(0.5))
        // Fast one-handed actions alongside the existing long-press
        // context menu (SongContextMenuContent, via SongRow) — 2026's
        // expected pattern per current gesture-UX research is swipe
        // actions with distinct semantics/tint per edge, not everything
        // buried behind a single long-press menu.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                library.toggleFavorite(songID: song.id)
            } label: {
                let isFav = library.isFavorite(songID: song.id)
                Label(isFav ? "Unfavorite" : "Favorite", systemImage: isFav ? "heart.slash.fill" : "heart.fill")
            }
            .tint(AppTheme.dynamicAccent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                player.insertNext(song: song)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .tint(AppTheme.success)
        }
        // Staggered entrance: first 20 rows slide in from the left
        .modifier(StaggeredSlideInModifier(
            index: flatIndex,
            maxIndex: 19,
            didAnimate: didAnimateEntrance
        ))
        // Windowed artwork prefetch: the initial onAppear below
        // only warms the first 30 — fine at the top of a 1,100-song
        // library, useless once the user scrolls past row 200.
        // `List` only calls onAppear for rows that actually become
        // visible, so this stays cheap (and `prefetch` itself skips
        // anything already cached) while keeping artwork ready a
        // little ahead of and behind wherever the user is scrolling.
        .onAppear {
            // Widened ahead/behind window when the active Lua
            // theme preset's `flags.aggressive_prefetch` is on
            // (see LuaFeatureFlags) — trades some extra network/
            // decode work for artwork being ready further in
            // advance of fast scrolling.
            let behind = LuaFeatureFlags.aggressivePrefetch ? 16 : 8
            let ahead = LuaFeatureFlags.aggressivePrefetch ? 48 : 24
            let lower = max(0, flatIndex - behind)
            let upper = min(sortedSongs.count, flatIndex + ahead)
            guard lower < upper else { return }
            ArtworkService.shared.prefetch(songs: Array(sortedSongs[lower..<upper]), pixelSize: 192)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !songs.isEmpty {
                songsHeroHeader
            }
            // Content — list or grid
            Group {
                if songColumns == 1 {
                    ScrollViewReader { proxy in
                        List {
                                if songs.isEmpty {
                                    EmptyLibraryView(
                                        isScanning: library.isScanning,
                                        onAddMusic: { showAddMusic = true },
                                        onScan: { library.requestAccessAndScan() }
                                    )
                                    .listRowBackground(Color.clear)
                                } else if showsIndexRail {
                                    // Sectioned-by-letter path — only taken for
                                    // Title/Artist sort with enough songs to make
                                    // an index worth having (see `showsIndexRail`).
                                    ForEach(alphaSections, id: \.letter) { section in
                                        Section {
                                            ForEach(section.songs) { song in
                                                songRowContent(song, flatIndex: songIndexCache[song.id] ?? 0)
                                            }
                                        } header: {
                                            Text(section.letter)
                                                .font(.footnote.weight(.heavy))
                                                .foregroundStyle(AppTheme.dynamicAccent)
                                                .id(section.letter)
                                        }
                                    }
                                } else {
                                    ForEach(Array(sortedSongs.enumerated()), id: \.element.id) { index, song in
                                        songRowContent(song, flatIndex: index)
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .onAppear {
                                guard !didAnimateEntrance else { return }
                                didAnimateEntrance = true
                            }
                            .onChange(of: sortedSongs.first?.id) { _ in
                                // Re-trigger entrance animation when the song list changes substantially
                                didAnimateEntrance = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    didAnimateEntrance = true
                                }
                            }
                            .overlay(alignment: .trailing) {
                                if showsIndexRail {
                                    AlphabetIndexRail(letters: alphaSections.map(\.letter)) { letter in
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            proxy.scrollTo(letter, anchor: .top)
                                        }
                                    }
                                    .padding(.trailing, 2)
                                }
                            }
                    }
                } else {
                    ScrollView {
                        if songs.isEmpty {
                            EmptyLibraryView(
                                isScanning: library.isScanning,
                                onAddMusic: { showAddMusic = true },
                                onScan: { library.requestAccessAndScan() }
                            )
                            .padding(.top, 60)
                        } else {
                            // More breathing room and a heavier per-tile shadow
                            // than the old grid (column count is still the
                            // user's own 1/2/3 toggle, unchanged) so this reads
                            // as a deliberate "card wall" instead of a denser
                            // version of the list.
                            LazyVGrid(columns: gridColumns, spacing: 20) {
                                ForEach(sortedSongs) { song in
                                    Button {
                                        player.play(song: song, in: sortedSongs)
                                    } label: {
                                        SongGridCell(song: song, isCurrent: player.currentSong?.id == song.id)
                                            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            // Extra clearance below the last row — a plain
                            // ScrollView's grid content was settling close
                            // enough to the MiniPlayerBar + tab bar that the
                            // last row could still peek through their
                            // translucent material while scrolling.
                            .padding(.bottom, 190)
                        }
                    }
                    .background(Color.clear.ignoresSafeArea())
                }
            }
        }
        // Keeps `sortedSongsCache` (see `sortedSongs`) current — every
        // modifier below that reads `sortedSongs` relies on one of these
        // having already run first, which holds true here since SwiftUI
        // fires same-event `.onAppear`/`.onChange` modifiers on one view in
        // the order they're attached.
        .onAppear { recomputeSortedSongs() }
        .onChange(of: songs) { _ in scheduleRecompute() }
        .onChange(of: sortOrderRaw) { _ in recomputeSortedSongs() }
        .onChange(of: pinFavoritesFirst) { _ in recomputeSortedSongs() }
        .onChange(of: library.favoriteSongIDs) { _ in recomputeSortedSongs() }
        .onAppear {
            // Warm the first 30 songs' artwork at background priority so
            // rows/cells have images ready before the user scrolls to them.
            ArtworkService.shared.prefetch(songs: Array(sortedSongs.prefix(30)), pixelSize: prefetchPixelSize)
        }
        .onChange(of: songs.count) { _ in
            // Re-trigger prefetch when the song list grows (e.g. after a scan).
            ArtworkService.shared.prefetch(songs: Array(sortedSongs.prefix(30)), pixelSize: prefetchPixelSize)
        }
        // NOTE: `.searchable` used to live here, but this view is
        // mounted/torn down every time the user switches the Library's
        // internal Songs/Albums/Artists/Genres/Folders tab, while the
        // `UISearchController` SwiftUI creates for `.searchable` is owned by
        // the enclosing `NavigationStack`, not by this view's lifecycle.
        // Tearing SongsTab down mid-presentation could leave that search
        // controller's full-screen dimming/obscuring view stuck in the
        // window hierarchy, silently swallowing every subsequent touch —
        // including taps on the app-level `CustomTabBar` — which is exactly
        // the "select Songs, then every tab is unresponsive" bug. Moved to
        // LibraryView's `NavigationStack` root (a stable view that's never
        // torn down) so the search controller is created once and just
        // toggles visibility per sub-tab instead of remounting. See
        // LibraryView.swift's `.searchable` call.
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Layout toggles
                Button {
                    UserDefaults.standard.set(1, forKey: "library_songs_columns")
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(songColumns == 1 ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)

                Button {
                    UserDefaults.standard.set(2, forKey: "library_songs_columns")
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(songColumns == 2 ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)

                Button {
                    UserDefaults.standard.set(3, forKey: "library_songs_columns")
                } label: {
                    Image(systemName: "square.grid.3x3")
                        .foregroundStyle(songColumns == 3 ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
// MARK: - Empty Library State (Songs tab)

private struct EmptyLibraryView: View {
    let isScanning: Bool
    let onAddMusic: () -> Void
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isScanning ? "waveform" : "music.note.list")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(AppTheme.dynamicAccent)

            Text(isScanning ? "Scanning…" : "No music yet")
                .font(.title2.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)

            if !isScanning {
                Text("Add music from your Files app, iTunes library, or connect via USB")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(spacing: 12) {
                    Button {
                        onAddMusic()
                    } label: {
                        Label("Add Music", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.dynamicAccent)

                    Button {
                        onScan()
                    } label: {
                        Label("Scan Apple Music Library", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.dynamicAccent)
                }
                .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
// MARK: - StaggeredSlideInModifier

/// Slides a view in from the left with a per-index delay, capped at `maxIndex`.
/// Once `didAnimate` flips to true the animation fires once and the view
/// settles in its final position.
private struct StaggeredSlideInModifier: ViewModifier {
    let index: Int
    let maxIndex: Int
    let didAnimate: Bool

    private var cappedIndex: Int { min(index, maxIndex) }
    private var delay: Double { Double(cappedIndex) * 0.03 }

    func body(content: Content) -> some View {
        content
            .opacity(didAnimate ? 1 : 0)
            .offset(x: didAnimate ? 0 : -30)
            .animation(
                didAnimate
                    ? .spring(response: 0.38, dampingFraction: 0.78).delay(delay)
                    : .none,
                value: didAnimate
            )
    }
}
