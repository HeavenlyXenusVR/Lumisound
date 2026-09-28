import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    // MARK: - Library Snapshot (instant-on-launch cache)

    private struct LibrarySnapshot: Codable {
        let songs: [Song]
        let artists: [String]
        let albums: [String]
        let genres: [String]
        /// The locally-imported subset, persisted separately from `songs`.
        ///
        /// `songs` is the COMBINED list (media library + imported) that the UI
        /// renders, and restoring it was enough to make the library appear
        /// instantly — which is why the gap here went unnoticed. But
        /// `performLocalDocumentsScan` diffs against `importedSongs`, not
        /// `allSongs`, so leaving this unrestored meant `existingURLs` was empty
        /// on every launch and the scan's entire "only process files we haven't
        /// seen before" optimisation never engaged: all ~3,500 files were treated
        /// as new, every launch, and the full main-actor merge plus index rebuild
        /// ran each time. Field telemetry showed it plainly — `librarySize: 0`
        /// alongside `newSongs: 3546` on every single scan.
        ///
        /// Optional so a snapshot written by an older build still decodes; those
        /// simply fall back to the previous behaviour for one launch, until the
        /// next persist writes the field.
        let importedSongs: [Song]?
    }

    private static let snapshotURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("library_snapshot_v1.json")
    }()

    /// Reads the last-persisted library state so `allSongs` (and the derived
    /// facet lists) are populated moments after `LibraryManager` is
    /// constructed — before any scan has run. For a 1,100-song library the
    /// real scan can take many seconds; without this, the launch/library
    /// screens sit empty that whole time even though the user had a perfectly
    /// good library a moment ago. `scanMediaLibrary`/`scanLocalDocuments`/etc.
    /// always run after `init` and silently replace these values with fresh
    /// results once they complete (see `persistSnapshotIfSettled`).
    ///
    /// The file read + JSON decode — real work for a several-thousand-song
    /// library — run off the main actor in a `Task.detached`; only the final
    /// `@Published` assignment touches the main actor. This USED to run
    /// fully synchronously and get called directly from `init()`, which
    /// SwiftUI invokes (via `@StateObject`) before the very first frame can
    /// render — for a big library, that synchronous decode was slow enough
    /// to visibly freeze the launch screen's supposedly-continuous
    /// animations for its duration, the opposite of the "instant" library
    /// this feature exists to provide. Callers should fire this from a
    /// `Task`, not await it inline where a blocked launch screen would
    /// matter.
    func loadPersistedSnapshot() async {
        let url = Self.snapshotURL
        // The lookup indexes are rebuilt from the snapshot too, not just
        // `allSongs`. Without them, anything that resolves songs by id in the
        // window before the first scan finishes gets nothing back — Home's
        // Quick Access built every playlist tile as "0 songs" with no
        // artwork, and because the scan then lands with the same song count,
        // Home's `.task(id: allSongs.count)` never re-ran to correct it. Same
        // construction as `rebuildAllSongs()`.
        let restored: (snapshot: LibrarySnapshot,
                       byID: [String: Song],
                       byArtist: [String: [Song]],
                       byAlbum: [String: [Song]],
                       byGenre: [String: [Song]])? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data),
                  !snapshot.songs.isEmpty
            else { return nil }
            let songs = snapshot.songs
            return (
                snapshot: snapshot,
                byID: Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                byArtist: Dictionary(grouping: songs, by: \.artistName),
                byAlbum: Dictionary(grouping: songs, by: \.groupableAlbumName),
                byGenre: Dictionary(grouping: songs.filter { !$0.genre.isEmpty }, by: \.genre)
            )
        }.value
        guard let restored else { return }
        let snapshot = restored.snapshot
        // Indexes first: `allSongs` is what views observe, so by the time it
        // publishes, lookups against it already work.
        songsByID = restored.byID
        songsByArtist = restored.byArtist
        songsByAlbum = restored.byAlbum
        songsByGenre = restored.byGenre
        allSongs = snapshot.songs
        artists = snapshot.artists
        albums = snapshot.albums
        genres = snapshot.genres
        // Restored only if the scan hasn't already populated it. Both this and
        // the launch scan are kicked off around the same moment, and this one
        // awaits a file read plus a JSON decode, so it can easily land second —
        // overwriting a freshly-scanned library with a stale snapshot would turn
        // a missed optimisation into actual data loss.
        if let imported = snapshot.importedSongs, importedSongs.isEmpty {
            importedSongs = imported
            appLog("Restored \(imported.count) imported song(s) from snapshot — scan will diff against these rather than treating every file as new",
                   category: "library")
        }
        appLog("Loaded cached library snapshot: \(snapshot.songs.count) song(s)", category: "library")
    }

    /// Writes the current library state to disk so the next launch can show it
    /// instantly via `loadPersistedSnapshot`. Only called once a scan has
    /// fully settled (`!isScanning`) so we never persist a half-populated
    /// mid-scan state as if it were the real library. Encoding/writing
    /// thousands of `Song` structs is real work — offloaded to a background
    /// task exactly like `ScanCacheService.persist()`.
    ///
    /// Debounced ~2s (separate from `rebuildAllSongs()`'s own 100ms debounce):
    /// `rebuildAllSongs()` runs once per single-song mutation too (e.g. one
    /// BPM analysis completing at a time, or a metadata correction), and each
    /// call used to trigger its own full snapshot re-encode+write. A run of
    /// several such mutations a few seconds apart — common while background
    /// BPM analysis works through a large library — now collapses into one
    /// disk write instead of one per mutation.
    func persistSnapshotIfSettled() {
        guard !isScanning else { return }
        pendingSnapshotPersistTask?.cancel()
        pendingSnapshotPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard let self, !Task.isCancelled, !self.isScanning else { return }
            let snapshot = LibrarySnapshot(
                songs: self.allSongs,
                artists: self.artists,
                albums: self.albums,
                genres: self.genres,
                importedSongs: self.importedSongs
            )
            let destination = Self.snapshotURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: destination, options: .atomic)
            }.value
        }
    }
}
