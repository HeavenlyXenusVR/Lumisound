import SwiftUI
import MediaPlayer

// MARK: - Tab enum

enum LibraryTab: String, CaseIterable {
    // The hub is the new default landing tab — a dashboard of shortcuts to
    // real playlists/folders/favorites plus a few auto-generated groupings
    // (see `LibraryHubView`). It sits *alongside* the traditional browsing
    // tabs below, elevating access to them rather than replacing anything —
    // every tab that existed before this redesign is still here, unchanged.
    case hub       = "Home"
    case songs     = "Songs"
    // Songs already merges mediaSongs (Apple Music/iTunes) + importedSongs
    // (manual imports/watched folders/Documents) into one flat list — this
    // tab exists alongside it specifically to surface just the Apple Music
    // subset (`LibraryManager.mediaSongs`) on its own, since that source has
    // its own permission/scan lifecycle (MPMediaLibrary authorization,
    // "songs found but not downloaded to this device", the scan crash-loop
    // guard) that's otherwise invisible once AddMusicView's sheet closes.
    case appleMusic = "Apple Music"
    case artists   = "Artists"
    case albums    = "Albums"
    case folders   = "Folders"
    case genres    = "Genres"
    case playlists = "Playlists"
    case favorites = "Favorites"
    case moods     = "Moods"

    var icon: String {
        switch self {
        case .hub:        return "square.grid.2x2.fill"
        case .songs:      return "music.note"
        case .appleMusic: return "music.note.house.fill"
        case .artists:    return "music.mic"
        case .albums:     return "square.stack"
        case .folders:    return "folder"
        case .genres:     return "guitars"
        case .playlists:  return "music.note.list"
        case .favorites:  return "heart"
        case .moods:      return "theatermasks"
        }
    }
}

// MARK: - Sort enum (Songs tab)

private enum LibrarySortOption: String, CaseIterable, Identifiable {
    case titleAZ          = "title_az"
    case artistAZ         = "artist_az"
    case dateAddedNewest  = "date_added_newest"
    case dateAddedOldest  = "date_added_oldest"
    case durationLongest  = "duration_longest"
    case durationShortest = "duration_shortest"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .titleAZ:          return "Title (A–Z)"
        case .artistAZ:         return "Artist (A–Z)"
        case .dateAddedNewest:  return "Date Added (Newest)"
        case .dateAddedOldest:  return "Date Added (Oldest)"
        case .durationLongest:  return "Duration (Longest)"
        case .durationShortest: return "Duration (Shortest)"
        }
    }

    var icon: String {
        switch self {
        case .titleAZ, .artistAZ:            return "textformat"
        case .dateAddedNewest, .dateAddedOldest: return "calendar"
        case .durationLongest, .durationShortest: return "clock"
        }
    }

    /// Applies this sort to a song list. `.dateAdded*` falls back to the local
    /// file's creation/modification date (there's no persisted "date added"
    /// field on `Song`) — streamed/cloud-only songs with no local file URL
    /// sort to the end under `.distantPast`.
    func apply(to songs: [Song]) -> [Song] {
        switch self {
        case .titleAZ:
            return songs.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .artistAZ:
            return songs.sorted { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
        case .dateAddedNewest:
            return songs.sorted { Self.fileDate($0) > Self.fileDate($1) }
        case .dateAddedOldest:
            return songs.sorted { Self.fileDate($0) < Self.fileDate($1) }
        case .durationLongest:
            return songs.sorted { $0.duration > $1.duration }
        case .durationShortest:
            return songs.sorted { $0.duration < $1.duration }
        }
    }

    /// Cached by song ID — `filteredSongs` recomputes on every `LibraryView`
    /// re-render (including ones triggered by unrelated `AudioPlayerManager`
    /// publishes like a track change or play/pause toggle), and without this
    /// cache each of those re-renders re-ran `FileManager.attributesOfItem`
    /// synchronously on the main thread for every song in the library when
    /// sorted by date added — a real stat-the-whole-library cost on every
    /// trigger, not just when the query/sort/library actually changed.
    private static var fileDateCache: [String: Date] = [:]

    private static func fileDate(_ song: Song) -> Date {
        if let cached = fileDateCache[song.id] { return cached }
        let date: Date
        if let url = song.url, url.isFileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let resolved = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) {
            date = resolved
        } else {
            date = .distantPast
        }
        fileDateCache[song.id] = date
        return date
    }
}

// MARK: - LibraryView

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var folderService: MusicFolderService
    @EnvironmentObject private var moodService: MoodPlaylistService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService

    @AppStorage("autoCloudBackup") private var autoCloudBackup: Bool = false
    @AppStorage("library_sort_option") private var sortOptionRaw: String = LibrarySortOption.titleAZ.rawValue
    // Mirrors SongsTab's own @AppStorage of the same key — multi-select is
    // only supported in the single-column List layout (see SongsTab), so the
    // toolbar's Select entry point is gated on it too.
    @AppStorage("library_songs_columns") private var songColumns: Int = 1

    @State private var selectedTab: LibraryTab = .hub
    @State private var searchText: String = ""
    @State private var debouncedSearch: String = ""
    @State private var filteredSongsState: [Song] = []
    @State private var showAddMusic = false
    @State private var showOpenSharedPlaylist = false
    @State private var backupSyncTask: Task<Void, Never>?

    // Songs tab multi-select
    @State private var isSelecting = false
    @State private var selectedSongIDs: Set<String> = []

    private var sortOption: LibrarySortOption {
        LibrarySortOption(rawValue: sortOptionRaw) ?? .titleAZ
    }

    // MARK: Filtered songs for Songs tab (uses debounced search)

    private func recomputeFilteredSongs() {
        let query = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = query.isEmpty ? library.allSongs : library.allSongs.filter { song in
            song.displayName.localizedCaseInsensitiveContains(query)
                || song.artistName.localizedCaseInsensitiveContains(query)
                || song.albumName.localizedCaseInsensitiveContains(query)
        }
        filteredSongsState = sortOption.apply(to: base)
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom scrollable tab bar
                LibraryTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Error banner — gains a real "Retry" button when the crash-loop
                // guard is active, since its message explicitly tells the user
                // to tap one (see LibraryManager.retryMediaLibraryScanAfterCrashGuard).
                if let error = library.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppTheme.warning)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(AppTheme.warning)
                            Spacer()
                        }
                        if library.scanCrashGuardActive {
                            Button {
                                library.retryMediaLibraryScanAfterCrashGuard()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(AppTheme.warning)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(AppTheme.surface.opacity(0.5))
                }

                // Tab content
                tabContent
            }
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            // Lives on the NavigationStack root — not on SongsTab, which is
            // mounted/torn down on every internal tab switch and previously
            // owned this modifier, occasionally leaving the search
            // controller's presentation stuck and swallowing all touches
            // (the "Songs tab locks out every other tab" bug). Always
            // present regardless of which internal tab is selected —
            // `SearchFieldPlacement.NavigationBarDrawerDisplayMode` has no
            // `.never` case to hide it conditionally, so unlike the old
            // per-screen `.searchable` this is visible on every Library
            // sub-tab, not just Songs. A harmless UX difference (the field
            // just does nothing on Albums/Artists/etc., same as before it
            // had a value typed in) in exchange for eliminating the mount/
            // unmount churn that caused the lockup.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search songs, artists, albums…"
            )
            .toolbar { toolbarItems }
            .task(id: "\(library.allSongs.count)|\(debouncedSearch)|\(sortOptionRaw)") {
                // Keep the O(n log n) Songs-tab query out of SwiftUI body
                // evaluation. Player progress and navigation state can
                // invalidate this root many times without changing the data.
                recomputeFilteredSongs()
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    LibrarySelectionActionBar(
                        selectedCount: selectedSongIDs.count,
                        onAddToPlaylist: { playlistID in
                            library.addSongs(ids: selectedSongIDs, toPlaylistID: playlistID)
                            isSelecting = false
                            selectedSongIDs.removeAll()
                        },
                        onDelete: {
                            library.removeImportedSongs(ids: selectedSongIDs)
                            isSelecting = false
                            selectedSongIDs.removeAll()
                        },
                        onCancel: {
                            isSelecting = false
                            selectedSongIDs.removeAll()
                        }
                    )
                    .environmentObject(library)
                } else {
                    MiniPlayerBar()
                }
            }
            .sheet(isPresented: $showAddMusic) {
                AddMusicView(onImportAppleMusic: { selectedTab = .appleMusic })
                    .environmentObject(library)
                    .environmentObject(folderService)
            }
            .sheet(isPresented: $showOpenSharedPlaylist) {
                CollaborativePlaylistView(playlist: nil)
                    .environmentObject(player)
                    .environmentObject(account)
                    .environmentObject(streaming)
                    .environmentObject(library)
            }
            .onAppear {
                let scanSource = UserDefaults.standard.string(forKey: "default_scan_source") ?? "apple_music"
                library.scanWatchedFolders(using: folderService)
                switch scanSource {
                case "app_storage":
                    library.scanLocalDocuments()
                case "both":
                    library.scanLocalDocuments()
                    library.requestAccessAndScan()
                default: // "apple_music" — also scan Documents for transferred files
                    library.scanLocalDocuments()
                    if library.allSongs.isEmpty && !library.isScanning {
                        library.requestAccessAndScan()
                    }
                }
                scheduleBackupSync()
            }
            // Debounce search: wait 0.3 s after the user stops typing
            .onChange(of: searchText) { newValue in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    if searchText == newValue {
                        debouncedSearch = newValue
                    }
                }
            }
            // Auto-Backup originally only fired on the "download from search" path,
            // so anything imported, scanned from Documents, or pulled from a watched
            // folder never made it to the cloud. Re-check whenever the library's
            // song count settles — scheduleBackupSync debounces so a multi-batch
            // scan triggers one sync, not dozens, and backUpLibraryIfNeeded itself
            // skips songs already present server-side.
            .onChange(of: library.allSongs.count) { _ in
                scheduleBackupSync()
            }
            .onChange(of: selectedTab) { _ in
                isSelecting = false
                selectedSongIDs.removeAll()
            }
            .onChange(of: songColumns) { _ in
                // Multi-select only applies to the single-column List layout —
                // drop out of it if the user switches to grid mid-selection.
                isSelecting = false
                selectedSongIDs.removeAll()
            }
        }
    }

    /// Debounces auto-backup catch-up so rapid library changes (a scan landing in
    /// several batches, an import finishing) collapse into a single sync pass.
    private func scheduleBackupSync() {
        guard autoCloudBackup, account.isLoggedIn, let token = account.token else { return }
        backupSyncTask?.cancel()
        let songs = library.allSongs
        backupSyncTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            streaming.backUpLibraryIfNeeded(songs: songs, token: token)
        }
    }

    // MARK: Tab content switcher

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .hub:
            LibraryHubView(selectedTab: $selectedTab)
        case .songs:
            SongsTab(
                songs: filteredSongsState,
                searchText: $searchText,
                showAddMusic: $showAddMusic,
                isSelecting: $isSelecting,
                selectedSongIDs: $selectedSongIDs
            )
        case .appleMusic:
            AppleMusicTab()
        case .artists:
            ArtistsTab()
        case .albums:
            AlbumsTab()
        case .folders:
            FoldersTab()
        case .genres:
            GenresTab()
        case .playlists:
            PlaylistsView()
        case .favorites:
            // LibraryView already paints the gallery background behind the
            // whole screen — see `drawsOwnBackground`.
            FavoritesView(drawsOwnBackground: false)
        case .moods:
            MoodPlaylistsView()
                .environmentObject(moodService)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if selectedTab == .songs && !filteredSongsState.isEmpty {
                Menu {
                    ForEach(LibrarySortOption.allCases) { option in
                        Button {
                            sortOptionRaw = option.rawValue
                        } label: {
                            Label(option.label, systemImage: option.icon)
                            if sortOption == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .tint(AppTheme.dynamicAccent)

                // Multi-select is only wired up for the single-column List
                // layout (see SongsTab) — grid-cell taps still just play.
                if songColumns == 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSelecting.toggle()
                            if !isSelecting { selectedSongIDs.removeAll() }
                        }
                    } label: {
                        Text(isSelecting ? "Done" : "Select")
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }

            Button {
                showOpenSharedPlaylist = true
            } label: {
                Image(systemName: "link.badge.plus")
            }
            .tint(AppTheme.dynamicAccent)

            if library.isScanning {
                ProgressView()
                    .tint(AppTheme.dynamicAccent)
            } else {
                Button {
                    Task {
                        // Thorough re-scan: picks up new, deleted, AND changed-in-place
                        // files (not just new ones), re-scans watched folders + Apple
                        // Music, then pulls the latest favorites/playlists/settings from
                        // the server — all without restarting the app.
                        await library.refreshAll(folderService: folderService)
                        if account.isLoggedIn {
                            await account.pullSync(library: library, player: player)
                        }
                        if let result = library.lastScanResult {
                            ToastCenter.shared.show(result, category: .success, icon: "arrow.clockwise")
                        }
                    }
                } label: {
                    if library.isScanning {
                        ProgressView().tint(AppTheme.dynamicAccent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .tint(AppTheme.dynamicAccent)
                .disabled(library.isScanning)
            }

            Button {
                showAddMusic = true
            } label: {
                Image(systemName: "plus")
            }
            .tint(AppTheme.dynamicAccent)
        }
    }
}
