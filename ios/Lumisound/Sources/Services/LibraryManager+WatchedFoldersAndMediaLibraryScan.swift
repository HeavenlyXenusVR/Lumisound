import Foundation

extension LibraryManager {

    /// Scans all user-selected folders tracked by `MusicFolderService` and adds
    /// any new audio files not already in the library.
    func scanWatchedFolders(using folderService: MusicFolderService) {
        // LibraryView can reappear during a background/foreground transition,
        // while the root launch task can request the same scan at the same
        // time. Coalesce those requests and avoid repeating a full folder
        // walk during a short reload burst.
        guard watchedFolderScanTask == nil,
              Date().timeIntervalSince(lastWatchedFolderScanDate) >= 30
        else { return }

        lastWatchedFolderScanDate = Date()
        let task = Task { await scanWatchedFoldersAsync(using: folderService) }
        watchedFolderScanTask = task
        Task { @MainActor in
            await task.value
            watchedFolderScanTask = nil
        }
    }

    /// Awaitable variant of `scanWatchedFolders(using:)` — used by callers
    /// (e.g. the duplicate finder) that need `allSongs` to reflect every
    /// watched-folder file before deciding what to do next.
    func scanWatchedFoldersAsync(using folderService: MusicFolderService) async {
        appLog("scanWatchedFolders: starting", category: "library")
        beginScan()
        defer { endScan() }
        let urls = folderService.resolveAll()
        guard !urls.isEmpty else {
            appLog("scanWatchedFolders: no accessible watched folders", category: "library")
            return
        }
        // Keep security-scoped access open until after makeSong reads the files.
        defer { for url in urls { url.stopAccessingSecurityScopedResource() } }

        let supportedExtensions = DocumentImportService.supportedExtensions
        let candidates = await Task.detached(priority: .utility) {
            var candidates: [URL] = []
            let fm = FileManager.default
            for baseURL in urls {
                let enumerator = fm.enumerator(
                    at: baseURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let url = enumerator?.nextObject() as? URL {
                    if Task.isCancelled { return candidates }
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    if supportedExtensions.contains(url.pathExtension.lowercased()) {
                        candidates.append(url)
                    }
                }
            }
            return candidates
        }.value

        guard !candidates.isEmpty else { return }

        let existingURLs = Set(importedSongs.compactMap { $0.url?.standardizedFileURL })
        let (cleanedCandidates, _) = Self.cleanUpConversionOrphans(among: candidates, existingURLs: existingURLs)
        let newURLs = cleanedCandidates.filter { !existingURLs.contains($0.standardizedFileURL) }
        guard !newURLs.isEmpty else { return }

        let newSongs = await resolveSongs(for: newURLs)

        appLog("scanWatchedFolders: \(newSongs.count) song(s) from \(urls.count) folder(s)", category: "library")
        RemoteLogger.log(category: "sync", event: "watched_folders_scan_completed",
                          detail: ["newSongs": newSongs.count, "folders": urls.count])
        importedSongs.append(contentsOf: newSongs)
        // Off the main actor — this was the same O(whole library) cost that
        // `runLocalDocumentsScan`'s "scan.dedupe" fix addressed for the
        // Documents scan path: `Dictionary(grouping:)` allocates a fresh
        // array per distinct key just to throw away every element but the
        // first, over the ENTIRE library, not just `newSongs` — and it ran
        // synchronously on the main actor on every watched-folder scan. That
        // fix never got applied here even though this path runs the exact
        // same dedupe; same Set-based filter, same detach, applied here too.
        let currentImportedSongs = importedSongs
        importedSongs = await Task.detached(priority: .userInitiated) {
            var seenKeys = Set<String>()
            seenKeys.reserveCapacity(currentImportedSongs.count)
            return currentImportedSongs.filter { song in
                let key = song.url.map { $0.standardizedFileURL.absoluteString } ?? song.id
                return seenKeys.insert(key).inserted
            }
        }.value
        rebuildAllSongs()

        // Push the updated folder structure (new tracks in watched folders)
        // to the server so it survives a reinstall — debounced, all
        // logged-in users, no opt-in toggle.
        if !newSongs.isEmpty {
            AccountService.shared?.scheduleFolderBackupPush(folderService: folderService, library: self)
        }
    }

    /// Scans a specific directory URL for audio files and adds any not already in the library.
    /// Designed for use with preset locations (Documents) that don't require a
    /// security-scoped bookmark — just a direct filesystem path the app can enumerate.
    func scanSpecificDirectory(_ url: URL) {
        appLog("scanSpecificDirectory: \(url.lastPathComponent)", category: "library")
        beginScan()
        lastScanResult = nil
        Task {
            defer { endScan() }

            let supportedExtensions = DocumentImportService.supportedExtensions
            let candidates = await Task.detached(priority: .utility) {
                var candidates: [URL] = []
                let fm = FileManager.default
                let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let fileURL = enumerator?.nextObject() as? URL {
                    if Task.isCancelled { return candidates }
                    guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    else { continue }
                    if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                        candidates.append(fileURL)
                    }
                }
                return candidates
            }.value

            // No audio files at all — return silently (not an error).
            guard !candidates.isEmpty else { return }

            let existingURLs = Set(importedSongs.compactMap { $0.url?.standardizedFileURL })
            let (cleanedCandidates, _) = Self.cleanUpConversionOrphans(among: candidates, existingURLs: existingURLs)
            let newURLs = cleanedCandidates.filter { !existingURLs.contains($0.standardizedFileURL) }

            // All files already in library — return silently.
            guard !newURLs.isEmpty else { return }

            let newSongs = await resolveSongs(for: newURLs)

            appLog("scanSpecificDirectory: \(newSongs.count) song(s) from \(url.lastPathComponent)", category: "library")
            importedSongs.append(contentsOf: newSongs)
            // Off the main actor — same O(whole library) `Dictionary(grouping:)`
            // cost as `scanWatchedFoldersAsync`'s identical fix above; see that
            // one's comment for why this ran synchronously on the main actor.
            let currentImportedSongs = importedSongs
            importedSongs = await Task.detached(priority: .userInitiated) {
                var seenKeys = Set<String>()
                seenKeys.reserveCapacity(currentImportedSongs.count)
                return currentImportedSongs.filter { song in
                    let key = song.url.map { $0.standardizedFileURL.absoluteString } ?? song.id
                    return seenKeys.insert(key).inserted
                }
            }.value
            rebuildAllSongs()
            lastScanResult = "Found \(newSongs.count) song\(newSongs.count == 1 ? "" : "s") in \(url.lastPathComponent)"
        }
    }

    /// Convenience: re-scans every local source — the Documents folder and
    /// all user-selected watched folders — so the "Refresh" button picks up
    /// files added or changed outside the app since the last scan, not just
    /// on next launch.
    func scanAll(folderService: MusicFolderService) {
        scanLocalDocuments()
        scanWatchedFolders(using: folderService)
    }

    func importFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        appLog("Importing \(urls.count) file(s)", category: "library")
        beginScan()
        errorMessage = nil

        Task {
            defer { endScan() }
            do {
                let imported = try await importer.importFiles(from: urls)
                appLog("Import complete: \(imported.count) file(s) added", category: "library")
                RemoteLogger.log(category: "sync", event: "file_import_completed",
                                  detail: ["imported": imported.count, "requested": urls.count])
                importedSongs.append(contentsOf: imported)
                // Off the main actor — same O(whole library) `Dictionary(grouping:)`
                // cost as `scanWatchedFoldersAsync`'s identical fix above; see that
                // one's comment for why this ran synchronously on the main actor.
                let currentImportedSongs = importedSongs
                importedSongs = await Task.detached(priority: .userInitiated) {
                    var seenKeys = Set<String>()
                    seenKeys.reserveCapacity(currentImportedSongs.count)
                    return currentImportedSongs.filter { song in
                        let key = song.url.map { $0.standardizedFileURL.absoluteString } ?? song.id
                        return seenKeys.insert(key).inserted
                    }
                }.value
                let songWord = imported.count == 1 ? "song" : "songs"
                ToastCenter.shared.show("Imported \(imported.count) \(songWord)", category: .success, icon: "tray.and.arrow.down.fill")
            } catch {
                appError("Import failed: \(error.localizedDescription)", category: "library")
                RemoteLogger.logError(category: "sync", event: "file_import_failed",
                                       message: error.localizedDescription,
                                       detail: ["requested": urls.count])
                errorMessage = error.localizedDescription
                ToastCenter.shared.show("Import failed: \(error.localizedDescription)", category: .error)
            }
            rebuildAllSongs()
        }
    }
}
