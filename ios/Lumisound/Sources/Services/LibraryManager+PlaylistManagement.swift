import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    func createPlaylist(name: String) {
        let playlist = Playlist(id: UUID(), name: name, songIDs: [], createdAt: Date())
        playlists.append(playlist)
        persistence.savePlaylists(playlists)
        appLog("createPlaylist: \"\(name)\" (id: \(playlist.id))", category: "library")
        ToastCenter.shared.show("Created playlist \"\(name)\"", category: .success, icon: "music.note.list")
    }

    /// Creates a playlist pre-populated with `songIDs`, in order — used by
    /// M3U import (see `M3UImportService`) so matched tracks land in the new
    /// playlist in one step instead of `createPlaylist` + N `addSong` calls
    /// (each of which would persist/rebuild on its own). Does not toast —
    /// the caller reports match counts, which a bare "created" toast can't.
    @discardableResult
    func createPlaylist(name: String, songIDs: [String]) -> Playlist {
        let playlist = Playlist(id: UUID(), name: name, songIDs: songIDs, createdAt: Date())
        playlists.append(playlist)
        persistence.savePlaylists(playlists)
        appLog("createPlaylist: \"\(name)\" (id: \(playlist.id), \(songIDs.count) song(s), pre-populated)", category: "library")
        return playlist
    }

    /// Merges a `LibraryBackup` into the current library — always additive,
    /// never overwrites/removes anything already here. Playlists are added
    /// as new playlists (fresh IDs, so re-importing the same backup twice
    /// just creates duplicates rather than silently merging song lists);
    /// any `songIDs`/favorite IDs the current library doesn't have (e.g. a
    /// song that only existed on the other device) are dropped rather than
    /// failing the whole import. Returns a summary for the caller to report.
    func importBackup(_ backup: LibraryBackup) -> (playlistsImported: Int, songsSkipped: Int) {
        appLog("importBackup: starting — \(backup.playlists.count) playlist(s), \(backup.favoriteSongIDs.count) favorite(s), exported \(backup.exportedAt) by v\(backup.appVersion)", category: "library")
        let knownIDs = Set(allSongs.map(\.id))
        var songsSkipped = 0

        var importedPlaylists: [Playlist] = []
        for var playlist in backup.playlists {
            let originalCount = playlist.songIDs.count
            playlist.songIDs = playlist.songIDs.filter { knownIDs.contains($0) }
            songsSkipped += originalCount - playlist.songIDs.count
            playlist = Playlist(
                id: UUID(),
                name: playlist.name,
                songIDs: playlist.songIDs,
                createdAt: Date(),
                folder: playlist.folder,
                tags: playlist.tags,
                preferredArtworkStyle: playlist.preferredArtworkStyle
            )
            importedPlaylists.append(playlist)
        }
        playlists.append(contentsOf: importedPlaylists)
        persistence.savePlaylists(playlists)

        let matchedFavorites = backup.favoriteSongIDs.filter { knownIDs.contains($0) }
        songsSkipped += backup.favoriteSongIDs.count - matchedFavorites.count
        favoriteSongIDs.formUnion(matchedFavorites)
        persistence.saveFavorites(favoriteSongIDs)

        appLog("importBackup: complete — \(importedPlaylists.count) playlist(s) imported, \(songsSkipped) song reference(s) skipped (not present locally)", category: "library")
        return (importedPlaylists.count, songsSkipped)
    }

    func deletePlaylist(_ playlist: Playlist) {
        DeletedPlaylistsStore.shared.trash(playlist)
        playlists.removeAll { $0.id == playlist.id }
        persistence.savePlaylists(playlists)
        appLog("deletePlaylist: \"\(playlist.name)\" (id: \(playlist.id), \(playlist.songIDs.count) song(s))", category: "library")
        ToastCenter.shared.show("Deleted playlist \"\(playlist.name)\"", category: .info, icon: "trash")
    }

    /// Re-adds a playlist trashed via `deletePlaylist` — see
    /// `DeletedPlaylistsView`. Preserves the playlist's original id, so any
    /// existing references to it (e.g. a Home dashboard shortcut) come
    /// back working rather than pointing at a since-deleted id.
    func restorePlaylist(_ playlist: Playlist) {
        guard !playlists.contains(where: { $0.id == playlist.id }) else { return }
        playlists.append(playlist)
        persistence.savePlaylists(playlists)
        appLog("restorePlaylist: \"\(playlist.name)\" (id: \(playlist.id))", category: "library")
        ToastCenter.shared.show("Restored playlist \"\(playlist.name)\"", category: .success, icon: "arrow.uturn.backward")
    }

    func renamePlaylist(_ playlist: Playlist, to newName: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        appLog("renamePlaylist: \"\(playlist.name)\" -> \"\(newName)\" (id: \(playlist.id))", category: "library")
        playlists[index].name = newName
        persistence.savePlaylists(playlists)
    }

    func setFolder(_ folder: String?, forPlaylistID playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
        playlists[index].folder = resolved
        persistence.savePlaylists(playlists)
        appLog("setFolder: playlist \(playlistID) -> \(resolved ?? "(none)")", category: "library")
    }

    func setTags(_ tags: [String], forPlaylistID playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].tags = tags
        persistence.savePlaylists(playlists)
        appLog("setTags: playlist \(playlistID) -> [\(tags.joined(separator: ", "))]", category: "library")
    }

    /// Remembers the Now Playing artwork style last used while this playlist
    /// was the active playback context — see `Playlist.preferredArtworkStyle`.
    func setPreferredArtworkStyle(_ styleRawValue: String, forPlaylistID playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        guard playlists[index].preferredArtworkStyle != styleRawValue else { return }
        playlists[index].preferredArtworkStyle = styleRawValue
        persistence.savePlaylists(playlists)
    }

    /// All folder names currently in use, sorted, for grouping the playlists list.
    var playlistFolders: [String] {
        Array(Set(playlists.compactMap(\.folder))).sorted()
    }

    /// Saves `settings` as this playlist's auto-applied EQ/effects/volume
    /// override — see `Playlist.audioSettingsOverride` and
    /// `AudioPlayerManager.applyTrackAudioSettings`.
    func setAudioSettingsOverride(_ settings: AudioSettings, forPlaylistID playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].audioSettingsOverride = settings
        persistence.savePlaylists(playlists)
    }

    func clearAudioSettingsOverride(forPlaylistID playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[index].audioSettingsOverride != nil else { return }
        playlists[index].audioSettingsOverride = nil
        persistence.savePlaylists(playlists)
    }
}
