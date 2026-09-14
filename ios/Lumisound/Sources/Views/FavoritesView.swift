import SwiftUI
import UIKit

// MARK: - Sort Order

private enum FavoritesSortOrder: String, CaseIterable {
    case title  = "Title"
    case artist = "Artist"
    // "Recently Added" removed: favoriteSongIDs is a Set<String> with no insertion order,
    // so there is no timestamp data to sort by.
}

// MARK: - FavoritesView

struct FavoritesView: View {
    /// Whether this instance paints the gallery background itself.
    ///
    /// It has to when PUSHED (LibraryHubView's shortcut destination) — a pushed
    /// view doesn't inherit the root's background and would otherwise sit on
    /// system black. It must NOT when EMBEDDED as one of `LibraryView`'s tabs,
    /// because LibraryView already paints one behind the whole screen: two
    /// instances then lay out independently, the outer spanning the full screen
    /// and this one only the tab-content area below the header, so the same
    /// wallpaper rendered twice at two different crops with a hard seam across
    /// the middle. Favorites was the only one of LibraryView's seven tabs doing
    /// this — every sibling (Songs, Albums, Folders, Genres, Playlists, Moods)
    /// already relies on LibraryView's — which is exactly why the split showed
    /// up on this tab alone.
    var drawsOwnBackground: Bool = true

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var sortOrder: FavoritesSortOrder = .title
    /// Same list/grid customization already available on Songs/Albums/Artists/
    /// Folders (see SongsTab/AlbumsTab's identical `@AppStorage` + toolbar
    /// menu pattern) — Favorites had no such control despite being just as
    /// much a song list as those tabs.
    @AppStorage("library_favorites_columns") private var favoritesColumns: Int = 1

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: favoritesColumns)
    }

    // MARK: Sorted favorites

    private var favorites: [Song] {
        let raw = library.favoriteSongs
        switch sortOrder {
        case .title:
            return raw.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .artist:
            return raw.sorted {
                let cmp = $0.artistName.localizedCaseInsensitiveCompare($1.artistName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    // MARK: Body

    /// Hero-forward header — a blurred backdrop drawn from the top favorite,
    /// mirroring the Songs tab's own hero. Replaces the old plain "Favorites"
    /// large-title + flat stat caption.
    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            HeroArtworkBackdrop(song: favorites.first, height: 170)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Text("Favorites")
                        .font(.title.weight(.heavy))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                ScreenStatChip(icon: "music.note", text: "\(favorites.count) \(favorites.count == 1 ? "song" : "songs")")
                playAllShuffleRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    var body: some View {
        Group {
            if favoritesColumns == 1 {
                List {
                    if favorites.isEmpty {
                        emptyState.listRowBackground(Color.clear)
                    } else {
                        Section {
                            heroHeader
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listSectionSeparator(.hidden)

                        // Favorites list
                        ForEach(favorites) { song in
                            FavoriteRow(song: song, isCurrent: player.currentSong?.id == song.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    player.play(song: song, in: favorites)
                                }
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(AppTheme.elevatedSurface.opacity(0.6))
                                )
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        library.toggleFavorite(songID: song.id)
                                    } label: {
                                        Label("Unfavorite", systemImage: "heart.slash")
                                    }
                                    .tint(AppTheme.error)
                                }
                        }
                    }
                }
                // `.plain`, not `.insetGrouped` — matches every other song-list screen
                // (SongsTab, ArtistsTab, GenresTab, PlaylistsView, Artist/AlbumDetailView).
                // `.insetGrouped` renders each Section as its own floating rounded card
                // with real gaps between them, and with `.scrollContentBackground(.hidden)`
                // those gaps show the full gallery background straight through —
                // exactly the "UI is split into disconnected pieces" look reported
                // against this screen specifically (every other tab already used `.plain`).
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ScrollView {
                    if favorites.isEmpty {
                        emptyState.padding(.top, 60)
                    } else {
                        heroHeader

                        LazyVGrid(columns: gridColumns, spacing: 20) {
                            ForEach(favorites) { song in
                                Button {
                                    player.play(song: song, in: favorites)
                                } label: {
                                    SongGridCell(song: song, isCurrent: player.currentSong?.id == song.id)
                                        .shadow(color: .black.opacity(0.35), radius: 9, y: 5)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        library.toggleFavorite(songID: song.id)
                                    } label: {
                                        Label("Unfavorite", systemImage: "heart.slash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 190)
                    }
                }
                .background(Color.clear.ignoresSafeArea())
            }
        }
        // Own gallery/theme background (pushed detail views don't inherit the
        // root's), so it matches the rest of the app instead of system black —
        // but only when this instance actually owns the screen. See
        // `drawsOwnBackground`.
        .background {
            if drawsOwnBackground {
                GalleryBackgroundView().ignoresSafeArea()
            }
        }
        .navigationTitle("Favorites")
        // Inline, not `.large` — the new hero header carries its own "Favorites"
        // title treatment, so a large nav-bar title on top of it would just
        // duplicate it.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(FavoritesSortOrder.allCases, id: \.self) { order in
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
                    Button {
                        favoritesColumns = 1
                    } label: {
                        Label("1 Column", systemImage: "rectangle.grid.1x2")
                    }
                    Button {
                        favoritesColumns = 2
                    } label: {
                        Label("2 Columns", systemImage: "square.grid.2x2")
                    }
                    Button {
                        favoritesColumns = 3
                    } label: {
                        Label("3 Columns", systemImage: "square.grid.3x3")
                    }
                } label: {
                    Image(systemName: favoritesColumns == 1 ? "rectangle.grid.1x2" : favoritesColumns == 2 ? "square.grid.2x2" : "square.grid.3x3")
                }
                .tint(AppTheme.dynamicAccent)
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "heart.slash",
            title: "No favorites",
            message: "Long-press any song and choose \"Add to Favorites\"."
        )
    }

    private var playAllShuffleRow: some View {
        HStack(spacing: 12) {
            Button {
                player.setQueue(favorites, startIndex: 0, autoplay: true)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.dynamicAccent)

            Button {
                let shuffled = favorites.shuffled()
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
}

// MARK: - Favorite Row

private struct FavoriteRow: View {
    let song: Song
    let isCurrent: Bool

    @EnvironmentObject private var library: LibraryManager

    private let heartHaptic = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        HStack(spacing: 0) {
            SongRow(song: song, isCurrent: isCurrent)

            Button {
                heartHaptic.impactOccurred()
                library.toggleFavorite(songID: song.id)
            } label: {
                Image(systemName: "heart.fill")
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .font(.system(size: 18))
                    .padding(.leading, 12)
            }
            .buttonStyle(.plain)
        }
    }
}
