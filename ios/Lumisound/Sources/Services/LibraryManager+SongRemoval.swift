import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    /// Permanently removes a locally-imported/downloaded song: moves its
    /// backing file into Recently Deleted (recoverable for 30 days — see
    /// `RecentlyDeletedService`), drops it from `importedSongs`/`allSongs`,
    /// and removes any references to it from playlists and favorites. Used
    /// by the duplicate finder to delete redundant copies. Only works for
    /// imported songs (those with a file `url` and no `persistentID`) —
    /// songs from the Apple Music library can't be removed from within the
    /// app sandbox, so callers should filter those out before offering
    /// deletion.
    func removeImportedSong(id songID: String) {
        guard let song = importedSongs.first(where: { $0.id == songID }) else { return }
        if song.url != nil, !(RecentlyDeletedService.shared?.trash(song: song) ?? false) {
            // Trashing failed (e.g. the source is unreachable) — fall back to
            // a hard delete so the song doesn't get stuck un-removable.
            // Songs from user-watched folders (MusicFolderService) live
            // outside the app sandbox and are only reachable via a
            // security-scoped bookmark — without this, `removeItem` silently
            // fails (the `try?` swallows an error), the song disappears from
            // the library list, but the file stays on disk.
            if let url = song.url {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    appWarn("removeImportedSong: failed to delete file at \(url.path): \(error.localizedDescription)", category: "library")
                    ToastCenter.shared.show("Couldn't delete \"\(song.displayName)\" from disk", category: .error)
                    return
                }
            }
        }
        importedSongs.removeAll { $0.id == songID }
        favoriteSongIDs.remove(songID)
        persistence.saveFavorites(favoriteSongIDs)
        for index in playlists.indices {
            playlists[index].songIDs.removeAll { $0 == songID }
        }
        persistence.savePlaylists(playlists)
        rebuildAllSongs()
        ToastCenter.shared.show("Deleted \"\(song.displayName)\" — recoverable in Recently Deleted for 30 days", category: .info, icon: "trash")
    }

    /// Aria Lumi's auto duplicate-removal path — unlike `removeImportedSong`,
    /// this NEVER falls back to a hard delete when trashing fails (an
    /// autonomous action she takes on her own has to stay revertible; a
    /// user tapping "Delete" themselves already knows what they're doing
    /// and gets the hard-delete safety net instead). Returns `false` without
    /// touching anything if the trash move fails, leaving the song exactly
    /// as it was — the caller should treat that as "she couldn't act here,"
    /// not attempt any other removal path.
    @discardableResult
    func ariaRemoveDuplicate(id songID: String) -> Bool {
        guard let song = importedSongs.first(where: { $0.id == songID }), song.url != nil else { return false }
        guard RecentlyDeletedService.shared?.trash(song: song) ?? false else { return false }
        importedSongs.removeAll { $0.id == songID }
        favoriteSongIDs.remove(songID)
        persistence.saveFavorites(favoriteSongIDs)
        for index in playlists.indices {
            playlists[index].songIDs.removeAll { $0 == songID }
        }
        persistence.savePlaylists(playlists)
        rebuildAllSongs()
        return true
    }

    /// Aria Lumi's autonomous corrupt-file cleanup path — mirrors
    /// `ariaRemoveDuplicate`'s revert-first contract (never a hard delete on
    /// her own initiative) but works from a raw file URL rather than a known
    /// song id, since a corrupt file (an interrupted download, a truncated
    /// conversion) may never have made it into `importedSongs` at all.
    @discardableResult
    func ariaRemoveCorruptFile(at url: URL) -> Bool {
        if let song = importedSongs.first(where: { $0.url == url }) {
            guard RecentlyDeletedService.shared?.trash(song: song) ?? false else { return false }
            importedSongs.removeAll { $0.id == song.id }
            favoriteSongIDs.remove(song.id)
            persistence.saveFavorites(favoriteSongIDs)
            for index in playlists.indices {
                playlists[index].songIDs.removeAll { $0 == song.id }
            }
            persistence.savePlaylists(playlists)
            rebuildAllSongs()
            return true
        }
        // Not a tracked library song — e.g. a download that got interrupted
        // before it was ever adopted into `importedSongs`. Route through the
        // OS's own Trash (recoverable via the Files app) rather than
        // `removeItem`, so it stays revertible the same as a tracked song.
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    /// Bulk version of `removeImportedSong` for Library's multi-select "Delete"
    /// action — one rebuild/toast instead of one per song. IDs that aren't in
    /// `importedSongs` (e.g. Apple Music library tracks, which this can't
    /// delete) are silently skipped rather than failing the whole batch.
    func removeImportedSongs(ids songIDs: Set<String>) {
        let toDelete = importedSongs.filter { songIDs.contains($0.id) }
        guard !toDelete.isEmpty else { return }

        for song in toDelete {
            guard let url = song.url else { continue }
            let trashed = RecentlyDeletedService.shared?.trash(song: song) ?? false
            guard !trashed else { continue }
            // Trashing failed — fall back to a hard delete so the song
            // doesn't get stuck un-removable.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                appWarn("removeImportedSongs: failed to delete file at \(url.path): \(error.localizedDescription)", category: "library")
            }
        }

        let deletedIDs = Set(toDelete.map(\.id))
        importedSongs.removeAll { deletedIDs.contains($0.id) }
        favoriteSongIDs.subtract(deletedIDs)
        persistence.saveFavorites(favoriteSongIDs)
        for index in playlists.indices {
            playlists[index].songIDs.removeAll { deletedIDs.contains($0) }
        }
        persistence.savePlaylists(playlists)
        rebuildAllSongs()
        ToastCenter.shared.show(
            "Deleted \(deletedIDs.count) song\(deletedIDs.count == 1 ? "" : "s") — recoverable in Recently Deleted for 30 days",
            category: .info, icon: "trash"
        )
    }

    /// Re-adds a song restored from Recently Deleted (see
    /// `RecentlyDeletedService.restore`) back into the library.
    func readdRestoredSong(_ song: Song) {
        guard !importedSongs.contains(where: { $0.id == song.id }) else { return }
        importedSongs.append(song)
        rebuildAllSongs()
    }

    /// Applies a user-confirmed metadata correction (e.g. from AcoustIDService
    /// identification) to a single imported song. Unlike the periodic
    /// re-enrichment in `reenrichSongsMissingMetadata` — which only fills
    /// *empty* fields — this overwrites existing title/artist/album, since
    /// the user has explicitly reviewed and confirmed the match. Only affects
    /// the app's own record for the file (`ScanCacheService`'s cached Song),
    /// not the file's embedded tags.
    func applyMetadataCorrection(songID: String, title: String?, artist: String?, album: String?) {
        guard let index = importedSongs.firstIndex(where: { $0.id == songID }) else { return }
        var song = importedSongs[index]
        if let title, !title.isEmpty { song.title = title }
        if let artist, !artist.isEmpty { song.artist = artist }
        if let album, !album.isEmpty { song.album = album }
        importedSongs[index] = song

        if let url = song.url, let stamp = ScanCacheService.fileStamp(for: url) {
            ScanCacheService.shared.store(song: song, for: url, stamp: stamp)
            ScanCacheService.shared.persist()
        }
        rebuildAllSongs()
        ToastCenter.shared.show("Updated \"\(song.displayName)\"", category: .success, icon: "checkmark.circle")

        // If Aria Lumi previously resolved this file's metadata and the user
        // just corrected it to something different, report the correction so
        // she learns from it (see AccountService+Intelligence.swift). Silent,
        // best-effort — never blocks or surfaces an error to the user.
        if let filename = song.url?.lastPathComponent {
            Task {
                guard let resolution = await IntelligenceSuggestionCache.shared.lookup(filename),
                      let memoryID = resolution.memoryID,
                      resolution.title != song.title || resolution.artist != song.artist
                else { return }
                await AccountService.shared?.reportMetadataCorrection(
                    memoryID: memoryID, title: song.title, artist: song.artist
                )
            }
        }
    }

    /// Re-encodes an imported song stuck on a compatibility-fallback format
    /// (opus/webm/ogg — see `Song.usesCompatibilityFallbackFormat`) to AAC
    /// `.m4a` in place, so it plays through the full AVAudioEngine graph
    /// (EQ/pitch/crossfade/gapless/effects) instead of the reduced AVPlayer
    /// fallback. The old file is only deleted after the new one is written
    /// and confirmed playable.
    func convertImportedSongFormat(songID: String) async {
        guard let index = importedSongs.firstIndex(where: { $0.id == songID }),
              let oldURL = importedSongs[index].url,
              oldURL.isFileURL
        else { return }
        let songName = importedSongs[index].displayName

        let newURL = oldURL.deletingPathExtension().appendingPathExtension("m4a")
        guard await AudioEncoderService.shared.convertPermanently(oldURL, to: newURL) else {
            ToastCenter.shared.show("Couldn't convert \"\(songName)\"", category: .error, icon: "exclamationmark.triangle")
            return
        }

        // Re-resolve the index — this is async, and the library could have
        // mutated (e.g. the song was removed) while the conversion ran.
        guard let freshIndex = importedSongs.firstIndex(where: { $0.id == songID }) else {
            try? FileManager.default.removeItem(at: newURL)
            return
        }
        var song = importedSongs[freshIndex]
        song.url = newURL
        importedSongs[freshIndex] = song
        try? FileManager.default.removeItem(at: oldURL)

        if let stamp = ScanCacheService.fileStamp(for: newURL) {
            ScanCacheService.shared.store(song: song, for: newURL, stamp: stamp)
            ScanCacheService.shared.persist()
        }
        rebuildAllSongs()
        ToastCenter.shared.show("Converted \"\(songName)\" for compatibility", category: .success, icon: "checkmark.circle")
    }

    /// Debounced rebuild — cancels any pending task and schedules a new one after 0.1 s.
    /// This prevents runaway work when rapid successive mutations occur (e.g. bulk imports).
    ///
    /// The locale-aware sort plus the three set/sort passes for filter facets are
    /// O(n log n) over the *entire* library on every mutation. For large libraries
    /// (thousands of tracks) that's enough synchronous work to visibly stall the UI
    /// if run on the main actor, so it's computed off-actor and only the final
    /// `@Published` assignment happens on the main actor.
    func rebuildAllSongs() {
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 s
            guard let self, !Task.isCancelled else { return }
            let media = self.mediaSongs
            let imported = self.importedSongs

            let (combined, artists, albums, genres, byID, byArtist, byAlbum, byGenre) = await Task.detached(priority: .userInitiated) {
                let combined = (media + imported).sortedByDisplayName()
                let artists = Array(Set(combined.map(\.artistName))).sorted()
                // `groupableAlbumName` (not `albumName`) so folder-name-inferred
                // pseudo-albums collapse into the same "Unknown Album" bucket as
                // genuinely untagged tracks, instead of each user folder showing
                // up as its own distinct entry in the Albums tab — see
                // `Song.groupableAlbumName` for the full rationale.
                let albums  = Array(Set(combined.map(\.groupableAlbumName))).sorted()
                let genres  = Array(Set(combined.compactMap { $0.genre.isEmpty ? nil : $0.genre })).sorted()
                // Built alongside the sort/group work above so `songs(byArtist:)` /
                // `songs(inAlbum:)` / `songs(inGenre:)` / `songs(for playlist:)`
                // never need to re-scan the full library per call — see the
                // `songsBy*` property doc comments in LibraryManager.swift.
                // NOT Dictionary(uniqueKeysWithValues:) — that variant TRAPS
                // (fatal error, crashes the app) if any two songs share an
                // id, which does happen: a race between the background
                // vault-conversion pass (which assigns a track a new id/URL
                // after re-encoding) and a concurrent local-documents scan
                // discovering that same freshly-written file before the
                // conversion pass finishes updating `importedSongs` can leave
                // two array entries independently resolving to the same
                // "local:<path>" id. `uniquingKeysWith:` keeps the first
                // (the one already in `combined`'s stable sort order) and
                // silently drops the duplicate instead of crashing — the
                // dupe is transient (the next scan/conversion pass settles
                // it) and duplicate-finder features exist for the case
                // where it isn't.
                let byID = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let byArtist = Dictionary(grouping: combined, by: \.artistName)
                let byAlbum  = Dictionary(grouping: combined, by: \.groupableAlbumName)
                let byGenre  = Dictionary(grouping: combined.filter { !$0.genre.isEmpty }, by: \.genre)
                return (combined, artists, albums, genres, byID, byArtist, byAlbum, byGenre)
            }.value

            guard !Task.isCancelled else { return }
            self.allSongs = combined
            self.artists = artists
            self.albums  = albums
            self.genres  = genres
            self.songsByID     = byID
            self.songsByArtist = byArtist
            self.songsByAlbum  = byAlbum
            self.songsByGenre  = byGenre
            self.persistSnapshotIfSettled()
        }
    }
}
