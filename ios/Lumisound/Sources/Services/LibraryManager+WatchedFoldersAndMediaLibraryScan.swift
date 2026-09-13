import Foundation
import MediaPlayer
import UIKit

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
        let (cleanedCandidates, _) = cleanUpConversionOrphans(among: candidates, existingURLs: existingURLs)
        let newURLs = cleanedCandidates.filter { !existingURLs.contains($0.standardizedFileURL) }
        guard !newURLs.isEmpty else { return }

        let newSongs = await resolveSongs(for: newURLs)

        appLog("scanWatchedFolders: \(newSongs.count) song(s) from \(urls.count) folder(s)", category: "library")
        RemoteLogger.log(category: "sync", event: "watched_folders_scan_completed",
                          detail: ["newSongs": newSongs.count, "folders": urls.count])
        importedSongs.append(contentsOf: newSongs)
        importedSongs = Array(Dictionary(grouping: importedSongs, by: { song in song.url.map { $0.standardizedFileURL.absoluteString } ?? song.id }).compactMap { $0.value.first })
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
            let (cleanedCandidates, _) = cleanUpConversionOrphans(among: candidates, existingURLs: existingURLs)
            let newURLs = cleanedCandidates.filter { !existingURLs.contains($0.standardizedFileURL) }

            // All files already in library — return silently.
            guard !newURLs.isEmpty else { return }

            let newSongs = await resolveSongs(for: newURLs)

            appLog("scanSpecificDirectory: \(newSongs.count) song(s) from \(url.lastPathComponent)", category: "library")
            importedSongs.append(contentsOf: newSongs)
            importedSongs = Array(Dictionary(grouping: importedSongs, by: { song in song.url.map { $0.standardizedFileURL.absoluteString } ?? song.id }).compactMap { $0.value.first })
            rebuildAllSongs()
            lastScanResult = "Found \(newSongs.count) song\(newSongs.count == 1 ? "" : "s") in \(url.lastPathComponent)"
        }
    }

    /// Convenience: re-scans every local source — the Documents folder, all
    /// user-selected watched folders, and (if previously granted) the Apple
    /// Music library — so the "Refresh" button picks up files added or
    /// changed outside the app since the last scan, not just on next launch.
    func scanAll(folderService: MusicFolderService) {
        scanLocalDocuments()
        scanWatchedFolders(using: folderService)
        // Only re-scan Apple Music if access was already granted — calling
        // `scanMediaLibrary()` without that check would trigger a permission
        // prompt for users who've never used the Apple Music Transfer feature.
        if MPMediaLibrary.authorizationStatus() == .authorized {
            scanMediaLibrary()
        }
    }

    func requestAccessAndScan() {
        appLog("requestAccessAndScan: requesting media library authorization", category: "library")
        Task {
            let existing = MPMediaLibrary.authorizationStatus()
            // Already denied/restricted — system won't re-prompt; send user to Settings.
            if existing == .denied || existing == .restricted {
                appWarn("requestAccessAndScan: access denied/restricted — opening Settings", category: "library")
                await UIApplication.shared.open(
                    URL(string: UIApplication.openSettingsURLString)!,
                    options: [:],
                    completionHandler: nil
                )
                errorMessage = "Open Settings → Privacy → Media & Apple Music to allow access."
                return
            }
            let status = await MPMediaLibrary.requestAuthorization()
            if status == .authorized {
                appLog("requestAccessAndScan: authorized, scanning", category: "library")
                errorMessage = nil
                scanMediaLibrary()
            } else if status == .denied || status == .restricted {
                appWarn("requestAccessAndScan: denied — opening Settings", category: "library")
                await UIApplication.shared.open(
                    URL(string: UIApplication.openSettingsURLString)!,
                    options: [:],
                    completionHandler: nil
                )
                errorMessage = "Open Settings → Privacy → Media & Apple Music to allow access."
            } else {
                appWarn("requestAccessAndScan: declined (status=\(status.rawValue))", category: "library")
                errorMessage = "Media library access was declined. Imported files still work."
            }
        }
    }

    /// Persists how many `scanMediaLibrary` runs in a row never reached completion.
    /// Survives process termination (unlike an in-memory flag), which is exactly
    /// what's needed to detect a crash loop: the counter is bumped *before* the
    /// scan starts and only cleared on success, so an app that crashes mid-scan
    /// comes back up, sees a non-zero count, and knows the previous attempt died.
    private static let scanAttemptCounterKey = "media_scan_incomplete_attempts"

    func scanMediaLibrary() {
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            requestAccessAndScan()
            return
        }

        // Crash-loop guard — `MPMediaQuery.songs().items` has been observed to
        // crash mid-read on some very large Apple Music libraries. Without this,
        // a crash here restarts the app straight back into the same scan: an
        // unrecoverable boot loop the user can only escape by deleting the app.
        // After 2 incomplete attempts in a row we stop trying automatically and
        // let the user fall back to imported/local files (still fully usable),
        // or switch scan sources from Settings.
        let defaults = UserDefaults.standard
        let priorAttempts = defaults.integer(forKey: Self.scanAttemptCounterKey)
        if priorAttempts >= 2 {
            appWarn("scanMediaLibrary: \(priorAttempts) consecutive incomplete attempts — refusing to retry automatically", category: "library")
            RemoteLogger.logError(category: "sync", event: "media_library_scan_crash_loop",
                                   message: "refusing to retry automatically",
                                   detail: ["priorAttempts": priorAttempts])
            scanCrashGuardActive = true
            errorMessage = "The media library scan has been crashing repeatedly. Imported/local files still work — switch \"Default Scan Source\" to App Storage in Settings, or tap Retry to try again."
            return
        }
        defaults.set(priorAttempts + 1, forKey: Self.scanAttemptCounterKey)

        appLog("scanMediaLibrary: starting (attempt \(priorAttempts + 1))", category: "library")
        appBreadcrumb("Started media library scan (attempt \(priorAttempts + 1))")
        beginScan()
        errorMessage = nil
        scanCrashGuardActive = false
        scanProgress = nil

        Task {
            defer { endScan() }
            // The query itself is the slow, blocking part — keep it off the main actor.
            let items: [MPMediaItem] = await Task.detached(priority: .userInitiated) {
                MPMediaQuery.songs().items ?? []
            }.value
            appLog("scanMediaLibrary: found \(items.count) item(s), converting", category: "library")

            // Convert in small chunks, each one's actual work done OFF the main
            // actor. This used to run `compactMap(Song.init(mediaItem:))`
            // directly in this @MainActor Task with just a `Task.yield()`
            // between chunks — the yield gives the run loop a chance to
            // interleave a frame between chunks, but each chunk's own 200
            // synchronous inits still ran back-to-back on the main actor
            // before that yield point, which was enough to read as a visible
            // stutter once per chunk throughout a big scan (confirmed: users
            // reported the UI "lags every single time" a big pass runs, i.e.
            // repeatedly during the scan, not just once) — the "cheap per
            // item" reasoning was true in isolation but didn't account for
            // 200 of them landing in one synchronous stretch. `Song.init
            // (mediaItem:)` only reads plain MPMediaItem properties (no
            // artwork decode, no UIKit), same as the `MPMediaQuery.songs()`
            // fetch just above already relies on being safe to touch off the
            // main actor — so `Task.detached` per chunk moves the real cost
            // off-main entirely; only the array append and `scanProgress`
            // publish (both cheap) stay on the main actor.
            var scanned: [Song] = []
            scanned.reserveCapacity(items.count)
            let chunkSize = 200
            var index = 0
            while index < items.count {
                guard !Task.isCancelled else { return }
                let end = min(index + chunkSize, items.count)
                let chunk = Array(items[index..<end])
                let converted = await Task.detached(priority: .userInitiated) {
                    chunk.compactMap(Song.init(mediaItem:))
                }.value
                scanned.append(contentsOf: converted)
                index = end
                scanProgress = LibraryScanProgress(current: index, total: items.count)
                await Task.yield()
            }

            appLog("scanMediaLibrary: found \(scanned.count) song(s)", category: "library")
            RemoteLogger.log(category: "sync", event: "media_library_scan_completed",
                              detail: ["found": scanned.count, "totalItems": items.count])
            self.mediaSongs = scanned
            self.rebuildAllSongs()
            self.scanProgress = nil
            // Completed cleanly — reset the crash-loop counter so future launches
            // get the normal 2-attempt grace again rather than accumulating forever.
            defaults.set(0, forKey: Self.scanAttemptCounterKey)
            appBreadcrumb("Media library scan completed: \(scanned.count) song(s)")

            // `Song.init(mediaItem:)` returns nil for items with no `assetURL`.
            // That's genuinely ambiguous between two different causes, and the
            // message below used to only account for one of them:
            //   1. A cloud-only track never downloaded to this device.
            //   2. A track downloaded and fully playable offline in Music, but
            //      still DRM-protected (FairPlay) — active Apple Music
            //      subscription streams, as opposed to purchased tracks or
            //      files synced via Finder/iTunes. iOS deliberately withholds
            //      `assetURL` for these from EVERY third-party app, precisely
            //      to prevent exactly this kind of extraction — there is no
            //      "download it properly" fix for case 2, and no public API
            //      distinguishes which of the two applies to a given skipped
            //      item, so the message can't claim more certainty than that.
            // The original copy only described (1) and told users to
            // "download them in the Music app, then scan again" — actively
            // misleading for anyone hitting (2), who may have already
            // downloaded hundreds of subscription tracks and will rescan
            // forever with no change, since no app-side fix exists for that.
            let skipped = items.count - scanned.count
            if skipped > 0 {
                let songWord = skipped == 1 ? "song" : "songs"
                if scanned.isEmpty {
                    self.errorMessage = "Found \(skipped) \(songWord) in your Apple Music library, but none could be imported. Usually this means Apple Music subscription tracks — iOS blocks every third-party app from reading those files, even ones fully downloaded for offline playback in Music. Only purchased tracks or files synced via Finder/iTunes can be imported this way."
                } else {
                    self.errorMessage = "Imported \(scanned.count) song(s). \(skipped) \(songWord) couldn't be imported — usually Apple Music subscription tracks, which iOS blocks every third-party app from reading even when fully downloaded. Only purchased tracks or files synced via Finder/iTunes can be imported this way."
                }
            }
        }
    }

    /// User-initiated escape hatch from the crash-loop guard above. The guard's
    /// banner tells the user to "tap Retry" — this is that action. Deliberately
    /// NOT wired into any automatic path (onAppear, app launch, etc.): resetting
    /// the counter there would silently recreate the exact boot loop the guard
    /// exists to break. Only reachable by an explicit tap, so a genuinely broken
    /// library can't trap the user in endless automatic retries, while a
    /// transient run of bad luck is just one button away from a fresh attempt.
    func retryMediaLibraryScanAfterCrashGuard() {
        guard scanCrashGuardActive else { return }
        appLog("retryMediaLibraryScanAfterCrashGuard: user-initiated retry — resetting attempt counter", category: "library")
        appBreadcrumb("User retried media library scan after crash-loop guard")
        UserDefaults.standard.set(0, forKey: Self.scanAttemptCounterKey)
        scanCrashGuardActive = false
        errorMessage = nil
        scanMediaLibrary()
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
                importedSongs = Array(
                    Dictionary(grouping: importedSongs, by: { song in song.url.map { $0.standardizedFileURL.absoluteString } ?? song.id })
                        .compactMap { $0.value.first }
                )
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
