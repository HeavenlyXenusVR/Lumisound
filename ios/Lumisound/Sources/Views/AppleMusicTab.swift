import SwiftUI
import MediaPlayer
import UIKit

// MARK: - Sort Order

private enum AppleMusicSortOrder: String, CaseIterable {
    case title      = "Title"
    case artist     = "Artist"
    case dateAdded  = "Date Added"
}

// MARK: - AppleMusicTab
//
// Library tab showing exactly what `LibraryManager.mediaSongs` holds — songs
// pulled from the device's Apple Music/iTunes library via `MPMediaQuery`
// (see `scanMediaLibrary()`), kept separate from `importedSongs` (manually
// imported files, watched folders, Documents) even though both get merged
// into `allSongs` for the main Songs tab. This tab exists specifically so
// "what did Apple Music actually give me" has its own home rather than being
// mixed anonymously into the general song list, and doubles as the
// permission/scan status surface for that source (AddMusicView's "iPhone
// Music Library" row triggers the same underlying scan but has no ongoing
// home of its own once the sheet is dismissed).
struct AppleMusicTab: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var sortOrder: AppleMusicSortOrder = .dateAdded
    @AppStorage("library_appleMusic_columns") private var columns: Int = 1

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }

    private var authorizationStatus: MPMediaLibraryAuthorizationStatus {
        MPMediaLibrary.authorizationStatus()
    }

    // MARK: Sorted songs

    /// Sorted once per change of the Apple Music songs or the sort order
    /// (see the `.onChange`s in `body`). This used to be a computed property —
    /// a full sort of every Apple Music song on each of the ~18 reads per
    /// render, and this tab re-renders on every player update.
    @State private var songs: [Song] = []

    private func sortedMediaSongs() -> [Song] {
        let raw = library.mediaSongs
        switch sortOrder {
        case .title:
            return raw.sortedByDisplayName()
        case .artist:
            return raw.sorted {
                let cmp = $0.artistName.localizedCaseInsensitiveCompare($1.artistName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .dateAdded:
            return raw.sorted {
                switch ($0.dateAdded, $1.dateAdded) {
                case let (a?, b?): return a > b
                case (nil, _?):    return false
                case (_?, nil):    return true
                default:
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            }
        }
    }

    // MARK: Body

    var body: some View {
        Group {
            switch authorizationStatus {
            case .authorized:
                if library.mediaSongs.isEmpty {
                    emptyOrScanningState
                } else {
                    songList
                }
            case .notDetermined:
                connectState
            case .denied, .restricted:
                deniedState
            @unknown default:
                connectState
            }
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
        .onAppear { songs = sortedMediaSongs() }
        .onChange(of: library.mediaSongs) { songs = sortedMediaSongs() }
        .onChange(of: sortOrder) { songs = sortedMediaSongs() }
        .navigationTitle("Apple Music")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if authorizationStatus == .authorized && !songs.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(AppleMusicSortOrder.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                HStack {
                                    Text(order.rawValue)
                                    if sortOrder == order {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .tint(AppTheme.dynamicAccent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { columns = 1 } label: { Label("1 Column", systemImage: "rectangle.grid.1x2") }
                        Button { columns = 2 } label: { Label("2 Columns", systemImage: "square.grid.2x2") }
                        Button { columns = 3 } label: { Label("3 Columns", systemImage: "square.grid.3x3") }
                    } label: {
                        Image(systemName: columns == 1 ? "rectangle.grid.1x2" : columns == 2 ? "square.grid.2x2" : "square.grid.3x3")
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }
            if authorizationStatus == .authorized {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if library.isScanning {
                        ProgressView().tint(AppTheme.dynamicAccent)
                    } else {
                        Button {
                            library.scanMediaLibrary()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .tint(AppTheme.dynamicAccent)
                    }
                }
            }
        }
    }

    // MARK: - Authorized, with songs

    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            HeroArtworkBackdrop(song: songs.first, height: 170)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "music.note.house.fill")
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Text("Apple Music")
                        .font(.title.weight(.heavy))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                ScreenStatChip(icon: "music.note", text: "\(songs.count) \(songs.count == 1 ? "song" : "songs")")
                playAllShuffleRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    private var songList: some View {
        Group {
            if columns == 1 {
                List {
                    Section {
                        heroHeader
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listSectionSeparator(.hidden)

                    ForEach(songs) { song in
                        Button {
                            player.play(song: song, in: songs)
                        } label: {
                            SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(AppTheme.elevatedSurface.opacity(0.6))
                        )
                        .listRowSeparator(.hidden)
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
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ScrollView {
                    heroHeader

                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(songs) { song in
                            Button {
                                player.play(song: song, in: songs)
                            } label: {
                                SongGridCell(song: song, isCurrent: player.currentSong?.id == song.id)
                                    .shadow(color: .black.opacity(0.35), radius: 9, y: 5)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    library.toggleFavorite(songID: song.id)
                                } label: {
                                    let isFav = library.isFavorite(songID: song.id)
                                    Label(isFav ? "Unfavorite" : "Favorite", systemImage: isFav ? "heart.slash.fill" : "heart.fill")
                                }
                                Button {
                                    player.insertNext(song: song)
                                } label: {
                                    Label("Play Next", systemImage: "text.insert")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 190)
                }
                .background(Color.clear.ignoresSafeArea())
            }
        }
    }

    private var playAllShuffleRow: some View {
        HStack(spacing: 12) {
            Button {
                player.setQueue(songs, startIndex: 0, autoplay: true)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.dynamicAccent)

            Button {
                let shuffled = songs.shuffled()
                player.setQueue(shuffled, startIndex: 0, autoplay: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.dynamicAccent)
        }
    }

    // MARK: - Authorized, but nothing scanned in yet (or actively scanning)

    private var emptyOrScanningState: some View {
        VStack(spacing: 16) {
            if library.isScanning {
                ProgressView()
                    .tint(AppTheme.dynamicAccent)
                    .scaleEffect(1.3)
                if let progress = library.scanProgress {
                    Text("Scanning \(progress.current) of \(progress.total) songs…")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text("Scanning your Apple Music library…")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            } else {
                EmptyStateView(
                    icon: "music.note.house",
                    title: "No Apple Music songs found",
                    message: library.scanCrashGuardActive
                        ? "The scan has been crashing repeatedly. Imported/local files still work — tap Retry to try again."
                        : "No importable songs found. If your library is Apple Music subscription tracks (not purchases or Finder-synced files), iOS blocks every third-party app from reading them — even ones fully downloaded for offline playback in Music. See the banner above for what was skipped and why."
                )
                Button {
                    if library.scanCrashGuardActive {
                        library.retryMediaLibraryScanAfterCrashGuard()
                    } else {
                        library.scanMediaLibrary()
                    }
                } label: {
                    Label(library.scanCrashGuardActive ? "Retry" : "Rescan", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.dynamicAccent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Not yet asked

    private var connectState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text("Connect Apple Music")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Import songs already downloaded to your iPhone from Apple Music or iTunes.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                library.requestAccessAndScan()
            } label: {
                Label("Connect", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.dynamicAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Denied / restricted

    private var deniedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.warning)
            Text("Access Denied")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Open Settings → Privacy → Media & Apple Music and allow Lumisound access, then come back here.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                library.requestAccessAndScan()
            } label: {
                Label("Open Settings", systemImage: "gearshape")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.dynamicAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
