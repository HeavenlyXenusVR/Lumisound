import Foundation
import Combine

// MARK: - TrackedPlaylist

/// A YouTube/SoundCloud playlist the user is tracking for on-demand downloads.
/// Distinct from `ArtistSubscription` (channel following): tracked playlists are
/// stored locally on the device and resolved to their tracks on demand via the
/// bridge's `/api/resolve`, so each item can be downloaded into the local
/// library (with duplicate detection) without a backend schema change.
struct TrackedPlaylist: Identifiable, Codable, Equatable {
    let id: String          // stable UUID string
    var url: String
    var name: String
    var thumbnailURL: String
    var dateAdded: Date
    /// Track count seen on the last successful resolve — lets the list show a
    /// hint ("32 tracks") without re-resolving every appearance.
    var lastTrackCount: Int
    /// When true, the app auto-downloads newly-added tracks from this playlist in
    /// the background. Optional so older persisted entries decode (missing = off).
    var autoDownload: Bool?
    /// Last time the auto-downloader checked this playlist (throttles checks).
    var lastAutoCheck: Date?
    /// Optional per-playlist destination subfolder under "Imported Music" (see
    /// `DownloadFolderPicker`) — lets this playlist's downloads land somewhere
    /// dedicated instead of the global Settings → yt-dlp → Download Folder.
    /// nil/empty falls back to that global setting. Optional so older persisted
    /// entries decode (missing = use the global default).
    var destinationFolder: String?

    var isAutoDownload: Bool { autoDownload ?? false }

    init(id: String = UUID().uuidString,
         url: String,
         name: String,
         thumbnailURL: String = "",
         dateAdded: Date = Date(),
         lastTrackCount: Int = 0,
         autoDownload: Bool? = nil,
         lastAutoCheck: Date? = nil,
         destinationFolder: String? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.thumbnailURL = thumbnailURL
        self.dateAdded = dateAdded
        self.lastTrackCount = lastTrackCount
        self.autoDownload = autoDownload
        self.lastAutoCheck = lastAutoCheck
        self.destinationFolder = destinationFolder
    }
}

// MARK: - TrackedPlaylistStore

/// Local, on-device persistence for tracked playlists (UserDefaults-backed).
/// Kept separate from the server-side channel subscriptions so it needs no DB
/// migration; the trade-off is that tracked playlists don't sync across devices.
@MainActor
final class TrackedPlaylistStore: ObservableObject {
    static let shared = TrackedPlaylistStore()

    @Published private(set) var playlists: [TrackedPlaylist] = []

    private let key = "trackedPlaylists.v1"

    init() { load() }

    // MARK: Mutations

    /// Adds a playlist if its URL isn't already tracked (case-insensitive,
    /// trimmed). Returns false if it was a duplicate or the URL was empty.
    @discardableResult
    func add(url: String, name: String, thumbnailURL: String = "") -> Bool {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return false }
        let normalized = trimmedURL.lowercased()
        guard !playlists.contains(where: { $0.url.lowercased() == normalized }) else { return false }

        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pl = TrackedPlaylist(
            url: trimmedURL,
            name: displayName.isEmpty ? defaultName(for: trimmedURL) : displayName,
            thumbnailURL: thumbnailURL
        )
        playlists.append(pl)
        save()
        return true
    }

    func remove(id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    /// Merges tracked playlists pulled from the account backup (see
    /// `AccountService.pullSync`) — adds any not already tracked (reusing
    /// `add`'s existing case-insensitive URL dedup) and carries over
    /// autoDownload/destinationFolder for newly-added entries only, so a
    /// playlist already tracked on this device keeps whatever settings it
    /// already has rather than being overwritten by a stale server value.
    func mergeFromSync(_ remote: [TrackedPlaylist]) {
        for entry in remote {
            let trimmedURL = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard add(url: trimmedURL, name: entry.name, thumbnailURL: entry.thumbnailURL) else { continue }
            guard let idx = playlists.firstIndex(where: { $0.url.lowercased() == trimmedURL.lowercased() }) else { continue }
            if let autoDownload = entry.autoDownload { playlists[idx].autoDownload = autoDownload }
            if let destinationFolder = entry.destinationFolder { playlists[idx].destinationFolder = destinationFolder }
        }
        save()
    }

    /// Updates the cached track count (and optionally the thumbnail/name) after a
    /// successful resolve.
    func updateMetadata(id: String, trackCount: Int? = nil, thumbnailURL: String? = nil, name: String? = nil) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        if let trackCount { playlists[idx].lastTrackCount = trackCount }
        if let thumbnailURL, !thumbnailURL.isEmpty { playlists[idx].thumbnailURL = thumbnailURL }
        if let name, !name.isEmpty { playlists[idx].name = name }
        save()
    }

    func setAutoDownload(id: String, _ on: Bool) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].autoDownload = on
        save()
    }

    /// Sets this playlist's destination subfolder (see `DownloadFolderPicker`).
    /// Pass "" to clear it and fall back to the global Download Folder setting.
    func setDestinationFolder(id: String, _ folder: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].destinationFolder = folder.isEmpty ? nil : folder
        save()
    }

    private func markAutoChecked(id: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].lastAutoCheck = Date()
        save()
    }

    // MARK: Auto-download

    /// Tracks in flight at once during a single playlist's auto-download
    /// pass (see `runAutoDownloads`). Matches the bridge's own
    /// `_YTDLP_SEMAPHORE` (main.py) exactly — the bridge already caps
    /// itself at this many concurrent yt-dlp processes GLOBALLY, across
    /// every user and every request path, so anything this client sends
    /// beyond that just queues there harmlessly. Sending this many at once
    /// (instead of 1) is what actually lets this client reach that existing
    /// server-side capacity instead of leaving slots idle the whole time.
    /// Dropped 4 -> 2 alongside _YTDLP_SEMAPHORE (2026-08): the bridge's
    /// host runs many other memory-capped containers on one small box, and
    /// 4-way concurrency was enough to push it into swapping/timing out
    /// under a burst of several playlists downloading at once.
    ///
    /// Back to 4 (2026-09), because the reason it was cut no longer holds. That
    /// cut predates the bridge's `_AdaptiveLimiter`, which samples MemAvailable
    /// and holds concurrency down to `_YTDLP_SAFE` (2) on its own whenever the
    /// host is actually under pressure — so the swapping this number was
    /// protecting against is now handled by the side that can actually measure
    /// it, instead of by a client guessing conservatively on the host's behalf.
    /// `_YTDLP_MAX` is 4 and this was the binding constraint: the client was
    /// leaving half the bridge's capacity idle even when the host was perfectly
    /// healthy, which is the failure mode this number was originally raised to
    /// fix. Anything beyond the bridge's own cap simply queues there harmlessly,
    /// so being wrong in this direction costs a little queueing, not a swap
    /// storm.
    private static let autoDownloadConcurrency = 4

    /// Guards against concurrent `runAutoDownloads` calls — it's triggered
    /// from two independent, uncoordinated sites (app launch/foreground in
    /// LumisoundApp.swift, and BackgroundRefreshService's BGAppRefreshTask
    /// handler), and `minInterval`/`lastAutoCheck` alone doesn't prevent
    /// overlap between them: `lastAutoCheck` is only updated (via
    /// `markAutoChecked`) after a playlist's full download batch completes,
    /// so two calls that start close together (e.g. app opened right as a
    /// background refresh fires) both see the same playlist as "due", both
    /// scan and compute their own `toGet` before either has downloaded
    /// anything, and both attempt the same "new" tracks in parallel. The
    /// per-download dedupe check in `downloadToLibrary` still catches and
    /// skips the actual write, but not before wasting a network round-trip
    /// and a yt-dlp job on the bridge for every track duplicated this way.
    private var isRunningAutoDownloads = false

    /// For each auto-download playlist not checked in the last `minInterval`,
    /// resolves it and downloads any tracks the user doesn't already have
    /// (deduped via `LibraryManager.hasLocalCopy`). Safe to call on launch /
    /// foreground; throttled so it doesn't re-resolve constantly.
    ///
    /// NOTE: lowering this doesn't buy true "every N minutes in the
    /// background" behavior on its own — this only controls whether a check
    /// is SKIPPED once one actually runs. Whether a check runs at all while
    /// backgrounded is entirely up to `BackgroundRefreshService`/iOS's
    /// `BGAppRefreshTask` scheduling (see its doc comment), which iOS
    /// throttles independently of anything here and offers no cadence
    /// guarantee. This just makes checks that DO happen (foreground, launch,
    /// or whenever iOS grants a background slot) far less likely to be
    /// skipped by this throttle.
    func runAutoDownloads(streaming: StreamingService,
                          library: LibraryManager,
                          minInterval: TimeInterval = 5 * 60) async {
        guard !isRunningAutoDownloads else { return }
        isRunningAutoDownloads = true
        defer { isRunningAutoDownloads = false }

        let now = Date()
        let due = playlists.filter { pl in
            guard pl.isAutoDownload else { return false }
            if let last = pl.lastAutoCheck { return now.timeIntervalSince(last) >= minInterval }
            return true
        }
        guard !due.isEmpty else { return }

        for pl in due {
            await library.scanLocalDocumentsAsync()
            let tracks = await streaming.fetchPlaylistTracks(url: pl.url, existingSongs: [])
            // Build the fast-path lookups ONCE before filtering — calling
            // hasLocalCopy(of:) per track (O(library) each) over a big
            // playlist was an O(tracks × library) main-thread hang long
            // enough to trip the watchdog. Same fix as
            // TrackedPlaylistDetailView.recomputeLocalCopies.
            let localSourceIDs = await library.localSourceIDs()
            let identityIndex = library.importedIdentityIndex()
            var seenSourceIDs = Set<String>()
            let toGet = tracks.filter {
                // Resolvers can return the same video more than once (for
                // repeated playlist entries). Never create two download jobs
                // for one source ID in the same pass.
                guard seenSourceIDs.insert($0.sourceTrackID).inserted else { return false }
                return !library.hasLocalCopy(of: $0, localSourceIDs: localSourceIDs, identityIndex: identityIndex)
            }
            let destinationDir = StreamingService.downloadDirectory(forFolderName: pl.destinationFolder)
            let existingSongsSnapshot = library.allSongs
            // `got`/`blocked` and the per-track work itself run on
            // `StreamingService`'s own MainActor isolation regardless of how
            // many `group.addTask` closures call into it concurrently —
            // actor isolation only serializes the SYNCHRONOUS stretches
            // between awaits, not the awaited work itself, so the slow part
            // of each download (network round-trips, the bridge's own
            // yt-dlp job) genuinely overlaps across these tasks rather than
            // queuing behind each other on the client. Was previously a
            // plain sequential `for track in toGet { await ... }` — one
            // track at a time — which, at the ~15-30s a job-based download
            // actually takes end-to-end (see the bridge's own request logs),
            // turned a several-hundred-track playlist into well over an
            // hour of serialized waiting even though the bridge itself was
            // sitting mostly idle the whole time.
            var got = 0
            var blocked = 0
            await withTaskGroup(of: (succeeded: Bool, wasBlocked: Bool).self) { group in
                var nextIndex = 0
                func startNext() {
                    guard nextIndex < toGet.count else { return }
                    let track = toGet[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            _ = try await streaming.downloadToLibrary(
                                track: track,
                                destinationDir: destinationDir,
                                existingSongs: existingSongsSnapshot,
                                destinationFolderName: pl.destinationFolder,
                                reportExistingAsSkipped: true
                            )
                            return (true, false)
                        } catch StreamingError.serverDetail {
                            // e.g. an auto-generated Topic-channel track
                            // blocked from extraction — tallied so the
                            // summary toast can explain why some tracks
                            // were skipped instead of silently dropping them.
                            return (false, true)
                        } catch StreamingError.alreadyDownloaded {
                            return (false, false)
                        } catch {
                            // Other failures (network, timeout, etc.) stay
                            // silent here — this is a background check, and
                            // the next scheduled run will simply retry them.
                            return (false, false)
                        }
                    }
                }
                for _ in 0..<min(Self.autoDownloadConcurrency, toGet.count) { startNext() }
                for await result in group {
                    if result.succeeded { got += 1 }
                    if result.wasBlocked { blocked += 1 }
                    startNext()
                }
            }
            if got > 0 {
                library.scanLocalDocuments()
                ToastCenter.shared.show("Auto-downloaded \(got) new track\(got == 1 ? "" : "s") from \"\(pl.name)\"",
                                        category: .download)
            }
            if blocked > 0 {
                ToastCenter.shared.show(
                    "\(blocked) track\(blocked == 1 ? "" : "s") from \"\(pl.name)\" blocked by YouTube (auto-generated \"Topic\" channel)",
                    category: .warning
                )
            }
            markAutoChecked(id: pl.id)
            if !tracks.isEmpty { updateMetadata(id: pl.id, trackCount: tracks.count) }
        }
    }

    // MARK: Helpers

    /// A readable fallback name derived from the playlist URL's `list=` id.
    private func defaultName(for url: String) -> String {
        if let comps = URLComponents(string: url),
           let list = comps.queryItems?.first(where: { $0.name == "list" })?.value, !list.isEmpty {
            return "Playlist \(list.prefix(8))"
        }
        return "Tracked Playlist"
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([TrackedPlaylist].self, from: data) {
            playlists = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
