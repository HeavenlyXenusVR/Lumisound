import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    // MARK: - Local Documents Scan

    /// Scans the app's Documents directory (root + Imported Music subfolder) for audio
    /// files and adds any that aren't already tracked. Called automatically on init and
    /// can be triggered manually after the user drops files via the Files app.
    /// Recursively scans the app's entire Documents directory for audio files and
    /// adds any not already tracked. Picks up files placed via Finder, Files app,
    /// iTunes file sharing, or any subdirectory the user created inside the app folder.
    func scanLocalDocuments() {
        // A scan is already running — `performLocalDocumentsScan` would just
        // have this new call join it anyway (see its own coalescing), but
        // calling `beginScan()` here FIRST regardless meant every redundant
        // trigger (the foreground-return observer firing more than once in
        // a burst, several screens' `.onAppear`/`.task` each requesting
        // their own scan around the same event — see that function's doc
        // comment: "FIVE OR MORE of these firing back-to-back") still
        // flipped the `@Published isScanning`/`scanProgress` state of its
        // own accord. `@Published` fires `objectWillChange` on every
        // assignment regardless of whether the value actually changed, so
        // each of those redundant calls forced a full SwiftUI re-render
        // across every view observing `LibraryManager` — a real, compounding
        // main-actor cost stacked on top of, not instead of, the (already
        // deduplicated) scan work itself. This is what actually produced the
        // visible "freezes when the app comes back from background, and it
        // happens 4-5 times" reports — not the scan's own disk I/O, which
        // was already off-main and already coalesced.
        guard Self.inFlightScanTask == nil else {
            Task { await performLocalDocumentsScan() }
            return
        }
        // Throttled the same way `scanWatchedFolders` already is: LibraryView
        // calls this from `.onAppear`, which SwiftUI fires every time the
        // view reappears — not just on a real app-foreground event, but on
        // every NavigationStack pop back to it AND every TabView switch back
        // to the Library tab (e.g. from Now Playing). None of those actually
        // mean anything on disk changed, so without this a user bouncing
        // between Library and Now Playing paid for a full Documents-tree
        // walk + eviction check on every single return. `scanLocalDocuments
        // Async` (Download All, TrackedPlaylistStore, pending-download
        // reconciliation) deliberately does NOT get this throttle — those
        // callers need an up-to-date result to make correct dedup decisions,
        // not just an opportunistic background refresh.
        guard Date().timeIntervalSince(lastLocalDocumentsScanDate) >= 30 else { return }
        lastLocalDocumentsScanDate = Date()
        beginScan()
        Task {
            defer { endScan() }
            await performLocalDocumentsScan()
        }
    }

    /// Thorough re-scan used by the Library "Refresh" button: re-reads files
    /// whose on-disk `(mtime, size)` changed since they were imported (e.g.
    /// tags edited in place via the Files app or a desktop tool), not just
    /// brand-new files — the periodic/automatic scan keeps its faster
    /// new-files-only path. Also re-scans watched folders and (if authorized)
    /// Apple Music, and publishes a `lastScanResult` summary the UI can toast.
    func refreshAll(folderService: MusicFolderService) async {
        beginScan()
        defer { endScan() }
        let before = importedSongs.count
        await performLocalDocumentsScan(force: true)
        await scanWatchedFoldersAsync(using: folderService)
        if MPMediaLibrary.authorizationStatus() == .authorized {
            scanMediaLibrary()
        }
        let after = allSongs.count
        let delta = after - before
        lastScanResult = delta > 0
            ? "Refreshed — \(after) songs (\(delta) new/updated)"
            : "Refreshed — \(after) songs, library is up to date"
    }

    /// Awaitable variant of `scanLocalDocuments()` — used by callers (e.g.
    /// "Download All") that need `allSongs` to reflect every locally-imported
    /// file, including any sitting in subfolders the user created or moved
    /// files into, *before* deciding what still needs to be downloaded.
    func scanLocalDocumentsAsync() async {
        // Same reasoning as scanLocalDocuments()'s guard above — several
        // callers (Download All, TrackedPlaylistStore auto-downloads,
        // pending-download reconciliation) can legitimately call this around
        // the same moment scanLocalDocuments()'s own trigger fires; join the
        // existing scan's isScanning state instead of also flipping it.
        guard Self.inFlightScanTask == nil else {
            await performLocalDocumentsScan()
            return
        }
        beginScan()
        defer { endScan() }
        await performLocalDocumentsScan()
    }

    /// Every completed download, missing-file self-heal, and several
    /// `.onAppear`/`.task` view modifiers each trigger their own local scan
    /// independently — under a burst of activity (a big batch download,
    /// dozens of tracks completing within milliseconds of each other) field
    /// logs showed FIVE OR MORE of these firing back-to-back in the same
    /// batch, each doing a full detached filesystem walk plus per-file
    /// metadata reads. `beginScan`/`endScan` only ever tracked a COUNT of
    /// concurrent scans for the UI spinner — it never actually prevented
    /// them from piling up. That's real, wasted concurrent work stacking up
    /// exactly when the device is already under the most load, and lines up
    /// with "the app freezes a lot with background downloads going on."
    /// Coalesce concurrent NON-forced scans into a single shared execution
    /// (the common case — every trigger above passes `force: false`);
    /// `force: true` (the explicit Library "Refresh" button) always runs
    /// its own fresh pass since that's a deliberate user action expecting
    /// an immediate re-read, not a share of whatever else is in flight.
    private static var inFlightScanTask: Task<Void, Never>?

    func performLocalDocumentsScan(force: Bool = false) async {
        if !force, let existing = Self.inFlightScanTask {
            appLog("performLocalDocumentsScan: already in flight, joining existing call instead of racing it", category: "library")
            await existing.value
            return
        }
        // A forced scan (the Library "Refresh" button) still shouldn't run
        // CONCURRENTLY with an already-in-flight regular one — both walk the
        // whole Documents tree and run `resolveSongs` over potentially
        // thousands of files, and a forced pass re-resolves EVERY candidate
        // rather than just new ones, so it's the heavier of the two. Caught
        // on screen: tapping Refresh right as an auto-download batch's own
        // scan was still wrapping up froze the UI for several seconds — two
        // full-library passes contending for the same CPU/IO budget at
        // once, not something either one's own off-main work alone
        // accounts for. Waiting here doesn't weaken the "always fresh"
        // guarantee `force` provides — this scan hasn't started reading
        // anything yet, so anything the other pass picks up is still
        // reflected once this one actually runs.
        if force, let existing = Self.inFlightScanTask {
            appLog("performLocalDocumentsScan(force): waiting for in-flight regular scan to finish first, rather than racing it", category: "library")
            await existing.value
        }
        let task = Task { await self.runLocalDocumentsScan(force: force) }
        if !force { Self.inFlightScanTask = task }
        await task.value
        if !force { Self.inFlightScanTask = nil }
    }

    private func runLocalDocumentsScan(force: Bool) async {
        appLog("Scanning local documents directory (force: \(force))", category: "library")
        // Instrumented because this path was the cause of the visible freezing
        // and nothing recorded how often it ran or what it cost. The frequency
        // had to be reconstructed by counting log lines and re-deriving the rate
        // from client timestamps; a scan that reports its own interval and
        // duration makes that answerable directly, and makes a regression
        // obvious rather than something to be rediscovered from a video.
        let scanStartedAt = Date()
        let secondsSinceLastScan = Self.lastScanStartedAt.map { scanStartedAt.timeIntervalSince($0) }
        Self.lastScanStartedAt = scanStartedAt
        guard FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first != nil else { return }

        // Snapshot the current library's local file URLs before hopping off the
        // main actor — cheap (URL/array copying, no I/O), and lets the eviction
        // check below run in the same background pass as the enumeration
        // instead of doing its own `fileExists` syscall per song back on the
        // main actor afterward.
        let existingSongURLs: [URL] = importedSongs.compactMap { $0.url }

        // Walk the full Documents tree OFF the main actor — LibraryManager is
        // @MainActor, so doing this enumeration inline blocked the UI every time
        // a screen scanned on appear (Subscriptions / tracked playlists / the
        // Cloud Services download flows), which is a big source of the "lag spike
        // when loading" reports on large libraries. Covers root, Imported Music/,
        // and any nested folders the user created.
        //
        // The eviction check (which local songs' backing files no longer exist)
        // rides along in this same detached pass for the same reason: it used
        // to run back on the main actor as a synchronous `fileExists` syscall
        // per already-imported song — for a library of thousands of tracks,
        // thousands of blocking stat() calls on the main thread on every single
        // scan (including scans triggered very frequently, like every
        // background-download completion) — a second, previously-unaccounted-for
        // source of the same "lag spike" class of report as the enumeration fix
        // above, just on the READ side of the library instead of the WRITE side.
        let (candidates, missingURLs): ([URL], Set<URL>) = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return ([], []) }
            var result: [URL] = []
            let enumerator = fm.enumerator(
                at: docsDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if DocumentImportService.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    result.append(url)
                }
            }
            let missing = existingSongURLs.filter { !fm.fileExists(atPath: $0.path) }
            return (result, Set(missing))
        }.value

        // Evict songs whose backing files no longer exist (e.g. moved by the user
        // via Files app into an organised subfolder, or the last local file was
        // deleted outright). Runs even when `candidates` is empty — an early
        // return before this point used to skip eviction entirely whenever the
        // Documents tree had zero audio files left, leaving phantom entries for
        // deleted tracks stuck in the library forever. Pure in-memory set
        // membership now (no I/O) — the actual stat() calls already happened
        // in the background pass above.
        // Always runs (not gated on `!missingURLs.isEmpty`) — a song with a nil
        // `url` must still be evicted every pass, same as before this change,
        // and the filter itself is cheap in-memory set membership now (no I/O),
        // so there's no cost to skip by short-circuiting here.
        let countBeforeEviction = importedSongs.count
        importedSongs = importedSongs.filter { song in
            guard let url = song.url else { return false }
            return !missingURLs.contains(url)
        }
        let evicted = countBeforeEviction != importedSongs.count

        // One-time-per-occurrence retroactive cleanup: `cleanUpConversionOrphans`
        // below only stops NEW duplicate pairs from being created going
        // forward — it has nothing to say about pairs that already both got
        // imported as separate importedSongs entries before this fix existed
        // (each scan that created one only ever compared it against files,
        // never against a sibling entry already sitting in the library).
        // Sweeps every scan (cheap — pure in-memory comparison over already-
        // loaded importedSongs, no disk I/O unless it actually finds a pair).
        let mergedDuplicates = mergeExistingConversionDuplicates()

        guard !candidates.isEmpty else {
            if evicted || mergedDuplicates > 0 { rebuildAllSongs() }
            return
        }

        let existingURLs = Set(importedSongs.compactMap { $0.url?.standardizedFileURL })
        let (cleanedCandidates, cleanedUpOrphans) = cleanUpConversionOrphans(among: candidates, existingURLs: existingURLs)
        guard !cleanedCandidates.isEmpty else {
            if evicted || mergedDuplicates > 0 || cleanedUpOrphans > 0 { rebuildAllSongs() }
            return
        }

        if force {
            // Refresh-button path: re-resolve EVERY candidate. `resolveSongs`
            // returns cached songs unchanged (cheap stat + dict hit) for files
            // whose (mtime, size) still matches, and re-extracts metadata only
            // for files that actually changed on disk — so in-place tag edits
            // are finally picked up, which the new-files-only path below misses.
            let resolved = await resolveSongs(for: cleanedCandidates)
            importedSongs = Array(
                Dictionary(grouping: resolved, by: { song in song.url.map { $0.standardizedFileURL.absoluteString } ?? song.id })
                    .compactMap { $0.value.first }
            )
            appLog("Local scan (force) complete: \(importedSongs.count) song(s)", category: "library")
            rebuildAllSongs()
            return
        }

        // Only process files we haven't seen before.
        let newURLs = cleanedCandidates.filter { !existingURLs.contains($0.standardizedFileURL) }
        guard !newURLs.isEmpty else { return }

        let newSongs = await resolveSongs(for: newURLs)

        let scanDuration = Date().timeIntervalSince(scanStartedAt)
        appLog("Local scan complete: \(newSongs.count) song(s) in \(String(format: "%.2f", scanDuration))s"
               + (secondsSinceLastScan.map { String(format: " (%.1fs since the previous scan)", $0) } ?? ""),
               category: "library")
        // Reported as a structured event, not just a log line, so the rate and
        // cost are queryable across every account instead of needing a
        // hand-written pattern match over free text.
        //
        // `sinceLastScanSeconds` is the field that matters: a scan taking 300ms
        // is fine on its own and ruinous ten times a minute, and only the
        // interval separates those two. Flagged when scans arrive closer together
        // than the throttle that is supposed to be governing them.
        RemoteLogger.log(
            category: "library",
            event: "local_scan_completed",
            level: (secondsSinceLastScan.map { $0 < 10 } ?? false) ? "warning" : "info",
            message: "\(newSongs.count) new song(s) in \(String(format: "%.2f", scanDuration))s",
            detail: [
                "durationMs": Int(scanDuration * 1000),
                "newSongs": newSongs.count,
                "librarySize": importedSongs.count,
                "forced": force,
                "sinceLastScanSeconds": secondsSinceLastScan.map { Int($0) } ?? -1,
            ]
        )
        importedSongs.append(contentsOf: newSongs)
        importedSongs = Array(Dictionary(grouping: importedSongs, by: { song in song.url.map { $0.standardizedFileURL.absoluteString } ?? song.id }).compactMap { $0.value.first })
        rebuildAllSongs()
    }

    /// Shared by every local-file scan path (Documents, watched folders,
    /// a specific directory): drops — and deletes on disk — any candidate
    /// that's a pre-conversion leftover, returning the cleaned candidate
    /// list plus how many were removed.
    ///
    /// A file whose exclusive-extension conversion target (`<name>.m4a.lms`)
    /// already exists — either already in the library (`existingURLs`), or
    /// right alongside it in this same scan batch — means
    /// `LumisoundExclusiveExtensionService.convert` re-encoded it
    /// successfully but failed to delete the original source afterward (a
    /// real, if rare, failure mode — see that function's doc comment).
    /// Every scan path used to import this leftover as if it were a
    /// genuinely separate file, which is exactly how "old file + .lms file,
    /// both showing up as separate library entries" duplicates happened.
    func cleanUpConversionOrphans(among candidates: [URL], existingURLs: Set<URL>) -> (candidates: [URL], cleanedUp: Int) {
        let allKnownConvertedURLs = existingURLs.union(
            candidates.filter { LumisoundExclusiveExtensionService.isConverted($0) }.map { $0.standardizedFileURL }
        )
        var remaining = candidates
        var cleanedUp = 0
        remaining.removeAll { candidate in
            guard let target = LumisoundExclusiveExtensionService.expectedConvertedURL(for: candidate) else { return false }
            guard allKnownConvertedURLs.contains(target.standardizedFileURL) else { return false }
            try? FileManager.default.removeItem(at: candidate)
            cleanedUp += 1
            return true
        }
        if cleanedUp > 0 {
            appLog("Local scan: cleaned up \(cleanedUp) pre-conversion leftover file(s) that already had a converted .lms counterpart", category: "library")
        }
        return (remaining, cleanedUp)
    }

    /// Retroactive counterpart to `cleanUpConversionOrphans` — that one only
    /// stops a NEW duplicate pair from forming; this finds pairs that
    /// already both made it into `importedSongs` as separate entries before
    /// that fix existed (each import only ever compared a candidate file
    /// against other FILES on disk, never against an existing library
    /// entry that happens to be its own converted counterpart). For every
    /// such pair, re-keys favorites/playlists/play-history from the old
    /// (pre-conversion) entry's id to the surviving `.lms` entry's id —
    /// same migration `LibraryManager.convertToLumisoundExclusiveExtension`
    /// already does for a live conversion — then deletes the old file and
    /// drops it from the library. Skips the currently-playing song (same
    /// "don't replace a file out from under an open player" reasoning as
    /// everywhere else in this pipeline); it's picked up on a later scan
    /// once it's no longer playing. Returns how many pairs were merged.
    @discardableResult
    func mergeExistingConversionDuplicates() -> Int {
        var convertedByTargetURL: [URL: Song] = [:]
        for song in importedSongs {
            guard let url = song.url, LumisoundExclusiveExtensionService.isConverted(url) else { continue }
            convertedByTargetURL[url.standardizedFileURL] = song
        }
        guard !convertedByTargetURL.isEmpty else { return 0 }

        let currentlyPlayingID = AudioPlayerManager.shared?.currentSong?.id
        var merged = 0

        for song in importedSongs {
            guard let url = song.url, !LumisoundExclusiveExtensionService.isConverted(url) else { continue }
            // See AudioPlayerManager.isInActiveQueue's doc comment — this
            // loop runs synchronously (no per-song async gap the way the
            // conversion pass has), but `currentlyPlayingID` is still only
            // ONE song; the survivor's target `.lms` file could be earlier
            // or later in the SAME queue as `song` without being the
            // literal current index, so it needs the same whole-queue check.
            guard song.id != currentlyPlayingID, AudioPlayerManager.shared?.isInActiveQueue(songID: song.id) != true else { continue }
            guard let target = LumisoundExclusiveExtensionService.expectedConvertedURL(for: url) else { continue }
            guard let survivor = convertedByTargetURL[target.standardizedFileURL] else { continue }

            if favoriteSongIDs.contains(song.id) {
                favoriteSongIDs.remove(song.id)
                favoriteSongIDs.insert(survivor.id)
                persistence.saveFavorites(favoriteSongIDs)
            }
            var playlistsChanged = false
            for i in playlists.indices {
                guard let pos = playlists[i].songIDs.firstIndex(of: song.id) else { continue }
                playlists[i].songIDs[pos] = survivor.id
                playlistsChanged = true
            }
            if playlistsChanged { persistence.savePlaylists(playlists) }
            PlayHistoryStore.shared.rekey(from: song.id, to: survivor.id)
            if let sourceTrackID = survivor.sourceTrackID, !sourceTrackID.isEmpty {
                DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: target.lastPathComponent)
            }

            try? FileManager.default.removeItem(at: url)
            importedSongs.removeAll { $0.id == song.id }
            merged += 1
        }

        if merged > 0 {
            appLog("Local scan: merged \(merged) existing pre-conversion/converted duplicate pair(s)", category: "library")
        }
        return merged
    }
}
