import SwiftUI

// MARK: - Routes

/// Every destination a Lumen navigation stack can push. Lumen's own screens
/// cover the everyday paths; the long tail of tools pushes the existing
/// screens, which pick up Lumen's palette through `AppTheme`.
enum LumenRoute: Hashable {
    // Lumen screens
    case album(String)
    case artist(String)
    case playlist(UUID)
    case genre(String)
    case favorites
    case recentlyAdded
    case mostPlayed
    case songs
    case albums
    case artists
    case playlists
    case genres
    case settings
    case settingsPage(SettingsView.SettingsTab)

    // Existing screens hosted inside Lumen
    case playlistEditor(UUID)
    case folders
    case appleMusic
    case moods
    case podcasts
    case smartPlaylists
    case discover
    case discoverMix
    case onThisDay
    case stats
    case achievements
    case rewind
    case heatmap
    case goal
    case timeCapsules
    case constellation
    case notifications
    case needleDrop
    case account
    case profile
    case friends
    case listenRooms
    case downloads
    case recentlyDeleted
    case libraryHealth
}

extension View {
    /// Registers the Lumen route table on a navigation stack's root.
    func lumenDestinations() -> some View {
        navigationDestination(for: LumenRoute.self) { route in
            LumenRouteDestination(route: route)
        }
    }
}

struct LumenRouteDestination: View {
    let route: LumenRoute

    @EnvironmentObject private var library: LibraryManager

    var body: some View {
        switch route {
        case .album(let name):
            LumenAlbumDetailView(album: name)
        case .artist(let name):
            LumenArtistDetailView(artist: name)
        case .playlist(let id):
            LumenPlaylistDetailView(playlistID: id)
        case .genre(let name):
            LumenSongCollectionView(kind: .genre(name))
        case .favorites:
            LumenSongCollectionView(kind: .favorites)
        case .recentlyAdded:
            LumenSongCollectionView(kind: .recentlyAdded)
        case .mostPlayed:
            LumenSongCollectionView(kind: .mostPlayed)
        case .songs:
            LumenSongsListView()
        case .albums:
            LumenAlbumsGridView()
        case .artists:
            LumenArtistsGridView()
        case .playlists:
            LumenPlaylistsView()
        case .genres:
            LumenGenresView()
        case .settings:
            LumenSettingsView()
        case .settingsPage(let page):
            SettingsView(lumenPage: page)
        case .playlistEditor(let id):
            if let playlist = library.playlists.first(where: { $0.id == id }) {
                hosted(PlaylistDetailView(playlist: playlist), title: playlist.name)
            } else {
                LumenEmptyState(systemImage: "music.note.list", title: "Playlist not found",
                                message: "It may have been deleted on another device.")
                    .lumenScreen()
            }
        case .folders:         hosted(FoldersTab(), title: "Folders")
        case .appleMusic:      hosted(AppleMusicTab(), title: "Apple Music")
        case .moods:           hosted(MoodPlaylistsView(), title: "Moods")
        case .podcasts:        hosted(PodcastsView(), title: "Podcasts")
        case .smartPlaylists:  hosted(SmartPlaylistsView(), title: "Smart Playlists")
        case .discover:        hosted(DiscoverView(), title: "Discover")
        case .discoverMix:     hosted(DiscoverMixView(), title: "Discover Mix")
        case .onThisDay:       hosted(OnThisDayView(), title: "On This Day")
        case .stats:           hosted(ListeningStatsView(), title: "Listening Stats")
        case .achievements:    hosted(AchievementsView(), title: "Achievements")
        case .rewind:          hosted(RewindView(), title: "Your Rewind")
        case .heatmap:         hosted(ListeningHeatmapView(), title: "Heatmap")
        case .goal:            hosted(ListeningGoalView(), title: "Listening Goal")
        case .timeCapsules:    hosted(TimeCapsulesView(), title: "Time Capsules")
        case .constellation:   hosted(ConstellationView(), title: "Constellation")
        case .notifications:   hosted(NotificationsView(), title: "Notifications")
        case .needleDrop:      hosted(NeedleDropView(), title: "Needle Drop")
        case .account:         hosted(AccountView(), title: "Account")
        case .profile:         hosted(MyProfileTabView(), title: "Profile")
        case .friends:         hosted(FriendsListView(), title: "Friends")
        case .listenRooms:     hosted(ListenRoomView(), title: "Listen Rooms")
        case .downloads:       hosted(DownloadsManagementView(), title: "Downloads")
        case .recentlyDeleted: hosted(RecentlyDeletedView(), title: "Recently Deleted")
        case .libraryHealth:   hosted(LibraryHealthView(), title: "Library Health")
        }
    }

    /// An existing screen pushed into a Lumen stack: Lumen's backdrop behind
    /// it (most of these screens draw `GalleryBackgroundView`, which also
    /// renders the Lumen backdrop in this edition) and a title fallback for
    /// the few that never set one.
    private func hosted<Content: View>(_ content: Content, title: String) -> some View {
        content
            .background(LumenBackdrop())
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
    }
}
