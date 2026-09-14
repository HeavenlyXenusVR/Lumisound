import Foundation
import MediaPlayer
import UIKit

/// Progress snapshot for an in-flight `scanMediaLibrary` run — lets the launch
/// screen show "Scanning 340 of 1,100 songs…" instead of a generic spinner for
/// users with big libraries, where the scan can take many seconds.
struct LibraryScanProgress: Equatable {
    let current: Int
    let total: Int
}

@MainActor
final class LibraryManager: ObservableObject {
    @Published var allSongs: [Song] = [] {
        didSet { Self.recomputeAmbiguousTitles(from: allSongs) }
    }

    /// `Song.ambiguityKey`s (title+artist) shared by more than one track, i.e.
    /// titles that don't actually identify anything. `Song.displayName` reads
    /// this to fall back to the filename for exactly those tracks — see its
    /// doc comment for why ambiguity, rather than filename word order, is the
    /// signal worth trusting.
    ///
    /// `static` because `displayName` is a plain computed property on a value
    /// type with no library context, matching how `shared` is already exposed
    /// for other non-view code. Recomputed on assignment rather than lazily so
    /// no view ever renders against a stale set mid-scan.
    private(set) static var ambiguousTitleKeys: Set<String> = []

    private static func recomputeAmbiguousTitles(from songs: [Song]) {
        var seen = Set<String>(minimumCapacity: songs.count)
        var duplicated = Set<String>()
        for song in songs where !song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = song.ambiguityKey
            if !seen.insert(key).inserted { duplicated.insert(key) }
        }
        ambiguousTitleKeys = duplicated
    }
    @Published var artists: [String] = []
    @Published var albums: [String] = []
    @Published var genres: [String] = []
    @Published var playlists: [Playlist] = []
    @Published var favoriteSongIDs: Set<String> = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: LibraryScanProgress? = nil
    /// Set when `scanMediaLibrary` has bailed out after repeated incomplete
    /// attempts (see the crash-loop guard in `scanMediaLibrary`). Lets the UI
    /// explain *why* the media library never loaded instead of just spinning.
    @Published var scanCrashGuardActive: Bool = false
    @Published var errorMessage: String?
    @Published var lastScanResult: String? = nil

    let persistence: PersistenceService
    let artwork: ArtworkService
    let importer = DocumentImportService()

    // Mirrors `AccountService.shared`/`StreamingService.shared` — gives
    // `BackgroundRefreshService` (invoked directly by iOS via BGTaskScheduler,
    // with no SwiftUI environment access) a way to reach the live library
    // instance for auto-downloading newly-found tracked-playlist tracks.
    static weak var shared: LibraryManager?

    /// Tracks how many scans (media library, local documents, watched folders,
    /// specific-directory) are currently in flight. `isScanning` reflects
    /// whether *any* of them are running, so the launch screen and library UI
    /// stay in "scanning" state for the full duration of a multi-scan launch
    /// instead of flipping to "done" as soon as the first scan finishes.
    var activeScanCount: Int = 0
    var watchedFolderScanTask: Task<Void, Never>?
    var lastWatchedFolderScanDate = Date.distantPast
    /// Throttle for `scanLocalDocuments()` — see that function's doc comment.
    var lastLocalDocumentsScanDate = Date.distantPast

    func beginScan() {
        activeScanCount += 1
        isScanning = true
    }

    func endScan() {
        activeScanCount = max(0, activeScanCount - 1)
        if activeScanCount == 0 {
            isScanning = false
        }
    }

    var mediaSongs: [Song] = []
    var importedSongs: [Song] = []

    // MARK: Indexed lookups (rebuilt alongside `allSongs` in `rebuildAllSongs()`)
    //
    // `songs(byArtist:)`/`songs(inAlbum:)`/`songs(inGenre:)`/`songs(for:)` used
    // to be a fresh `allSongs.filter { ... }` (or a fresh `Dictionary(uniqueKeysWithValues:)`
    // build for playlists) on every single call — and every visible row in the
    // Artists/Albums/Genres tabs and every row in the Playlists tab calls one of
    // these on every render. At a few hundred+ songs, with a few dozen visible
    // rows, that's thousands of full-array scans per render pass. These caches
    // turn each lookup into an O(1) dictionary read; they're plain (non-`@Published`)
    // stored properties since nothing observes them directly — only
    // `rebuildAllSongs()`'s existing `allSongs`/`artists`/`albums`/`genres`
    // publishes need to trigger a re-render, these just need to be *current* by
    // the time a row reads them.
    var songsByID: [String: Song] = [:]
    var songsByArtist: [String: [Song]] = [:]
    var songsByAlbum: [String: [Song]] = [:]
    var songsByGenre: [String: [Song]] = [:]

    /// Pending debounced rebuild task. Cancelled and replaced on each rapid mutation.
    var pendingRebuildTask: Task<Void, Never>?
    /// Pending debounced snapshot-persist task (see `persistSnapshotIfSettled`).
    /// Separate from `pendingRebuildTask`'s 100ms debounce: `rebuildAllSongs()`
    /// itself runs once per single-song mutation (e.g. each BPM analysis
    /// completing, one at a time, well outside that 100ms window), and every
    /// one of those was unconditionally re-encoding and writing the *entire*
    /// library snapshot to disk. This gives the disk write its own, longer
    /// debounce so a string of individual mutations collapses into one write.
    var pendingSnapshotPersistTask: Task<Void, Never>?

    var foregroundObserver: NSObjectProtocol?
    var metadataReenrichTimer: Timer?
    var isReenrichingMetadata = false
    var metadataRefreshTimer: Timer?
    var isRefreshingMetadata = false
    /// Set while `forceMetadataSync` is running, so the Settings button can
    /// show a spinner and avoid overlapping runs.
    @Published var isForcingMetadataSync = false
    /// Rotating cursor into `importedSongs` for `refreshNextMetadataBatch()` —
    /// advances by `metadataRefreshBatchSize` each tick so every track gets
    /// re-read eventually without ever doing a full-library pass in one go.
    var metadataRefreshCursor = 0

    var favoriteSongs: [Song] {
        allSongs.filter { favoriteSongIDs.contains($0.id) }
    }

    init(persistence: PersistenceService = .shared, artwork: ArtworkService = .shared) {
        self.persistence = persistence
        self.artwork = artwork
        Self.shared = self
        favoriteSongIDs = persistence.loadFavorites()
        playlists = persistence.loadPlaylists()
        // Show last session's library moments after launch — see
        // `loadPersistedSnapshot`. Fired as a Task (not awaited here) since
        // `init` runs before SwiftUI's first frame — awaiting inline would
        // block that frame on the file read/decode, freezing the launch
        // screen's animations for exactly as long as this took, which is
        // the bug `loadPersistedSnapshot` was rewritten to fix. The real
        // scans below always run afterward and overwrite this with fresh
        // data; this just removes the "empty list for several seconds"
        // window for users with big libraries (1000+ songs).
        Task { [weak self] in await self?.loadPersistedSnapshot() }
        // Re-scan local documents whenever the app returns to the foreground so
        // that files the user added via the Files app while Lumisound was
        // backgrounded are picked up without requiring a manual refresh.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanLocalDocuments() }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        metadataReenrichTimer?.invalidate()
        metadataRefreshTimer?.invalidate()
    }

}
