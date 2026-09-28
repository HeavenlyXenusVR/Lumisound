import Foundation

// MARK: - Screenshot mode
//
// Only used by the screenshot workflow (.github/workflows/screenshots-ios.yml
// and Lumisound/UITests/ScreenshotTests.swift). That workflow copies a
// generated demo library into the simulator's Documents folder and launches
// the app with `-LumisoundScreenshotMode`. With the flag set:
//   - `seed` gives the demo tracks listening history, favorites, two
//     playlists and a paused track, so Home's shelves have something to show.
//   - `LumisoundApp` skips launch work that would change the demo files or
//     cover the screen: the exclusive-extension conversion loop, the corrupt
//     and duplicate scanners (which can delete files), online metadata
//     re-enrichment, the notification permission prompt and the update check.
// Without the flag none of this runs.
enum ScreenshotMode {
    static let launchArgument = "-LumisoundScreenshotMode"
    static let isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)

    /// Waits for the initial Documents scan to settle, then seeds. Safe to
    /// run on every launch: history merges keep the larger count and later
    /// date, favorites are a set union, and playlists are matched by name.
    @MainActor
    static func seed(library: LibraryManager, player: AudioPlayerManager) async {
        var lastCount = -1
        var stableTicks = 0
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let count = library.allSongs.count
            stableTicks = (count > 0 && count == lastCount && !library.isScanning) ? stableTicks + 1 : 0
            lastCount = count
            if stableTicks >= 4 { break }
        }

        // Sorted so every run seeds the same songs the same way.
        let songs = library.allSongs.sorted { $0.title < $1.title }
        guard !songs.isEmpty else {
            appWarn("ScreenshotMode: no songs found to seed", category: "general")
            return
        }

        let now = Date()
        var history: [String: PlayHistoryEntry] = [:]
        for (index, song) in songs.enumerated() {
            switch index {
            case 0..<8:
                // Played today → Jump Back In, Recently Played, On Repeat.
                history[song.id] = PlayHistoryEntry(
                    playCount: 30 - index * 3,
                    lastPlayedAt: now.addingTimeInterval(-Double(index + 1) * 20 * 60)
                )
            case 8..<16:
                // Earlier this week → This Week recap.
                history[song.id] = PlayHistoryEntry(
                    playCount: 14 - (index - 8),
                    lastPlayedAt: now.addingTimeInterval(-Double(index - 6) * 86_400 * 0.7)
                )
            case 16..<22:
                history[song.id] = PlayHistoryEntry(
                    playCount: 3,
                    lastPlayedAt: now.addingTimeInterval(-Double(index + 4) * 86_400)
                )
            default:
                // Never played. Favorites among these become Forgotten Favorites.
                break
            }
        }
        PlayHistoryStore.shared.mergeFromSync(history)

        let favoriteIDs = Set(stride(from: 1, to: songs.count, by: 3).map { songs[$0].id })
        if !favoriteIDs.isSubset(of: library.favoriteSongIDs) {
            library.favoriteSongIDs.formUnion(favoriteIDs)
            library.persistence.saveFavorites(library.favoriteSongIDs)
        }

        let existingNames = Set(library.playlists.map(\.name))
        let demoPlaylists: [(name: String, songs: [Song])] = [
            ("Late Night Drive", Array(songs.prefix(8))),
            ("Focus Flow", Array(songs.suffix(8))),
        ]
        for playlist in demoPlaylists where !existingNames.contains(playlist.name) {
            library.createPlaylist(name: playlist.name, songIDs: playlist.songs.map(\.id))
        }

        // A loaded-but-paused track: fills Now Playing and shows Home's Resume card.
        if player.currentSong == nil {
            player.setQueue(Array(songs.prefix(8)), startIndex: 0, autoplay: false)
            player.savePlaybackState()
        }

        appLog("ScreenshotMode: seeded \(history.count) play histories, \(favoriteIDs.count) favorites", category: "general")
    }
}
