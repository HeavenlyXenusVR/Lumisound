import Foundation
import UIKit

@MainActor
final class MusicFolderService: ObservableObject {
    static let bookmarksKey = "music_folder_bookmarks_v1"

    @Published private(set) var watchedFolders: [WatchedFolder] = []

    struct WatchedFolder: Identifiable, Codable {
        let id: UUID
        var displayName: String
        var bookmarkData: Data
        var lastScannedAt: Date
        var trackCount: Int
    }

    /// Mirrors `AccountService.shared`/`LibraryManager.shared` — gives
    /// non-view code (e.g. `DiagnosticsSnapshotService`) a way to reach the
    /// live instance without needing it threaded through as a parameter.
    static weak var shared: MusicFolderService?

    init() {
        Self.shared = self
        loadBookmarks()
    }

    // MARK: - Local "Imported Music" subfolder grouping
    //
    // Shared by `FoldersTab` (the traditional Folders browsing tab) and
    // `LibraryHubView`'s speed-dial tiles, so both present the exact same
    // set of folders instead of two independently-written groupings quietly
    // drifting apart. Groups `songs` by their top-level subdirectory under
    // "Imported Music" — unlike the Albums tab, this is purely path-based:
    // every song physically inside a folder shows up here regardless of its
    // album metadata tag (or lack of one).
    struct LocalFolderGroup: Identifiable {
        let id: String   // folder name, unique within Imported Music
        let dirURL: URL
        let songs: [Song]
    }

    /// Computed off the render path by callers (e.g. via `.task(id:)`) —
    /// O(n) over `songs`, not something to run on every SwiftUI body pass
    /// for a large library. `nonisolated` (despite the enclosing class being
    /// `@MainActor`) so `FoldersTab` can actually run it inside a
    /// `Task.detached` off the main thread — it touches no instance state,
    /// only `FileManager` and its `songs` argument, so isolating it to the
    /// actor would just force every call back onto the main thread, which
    /// for a large library is exactly the multi-hundred-millisecond
    /// main-thread stall (repeated on every scan-triggered rebuild) that
    /// made the Folders grid freeze and lose scroll position.
    nonisolated static func localFolderGroups(from songs: [Song]) -> [LocalFolderGroup] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let importDir = docs.appendingPathComponent("Imported Music").standardizedFileURL
        let importPath = importDir.path

        var groups: [String: (url: URL, songs: [Song])] = [:]
        for song in songs {
            guard let url = song.url else { continue }
            let songPath = url.standardizedFileURL.path
            guard songPath.hasPrefix(importPath + "/") else { continue }
            let remainder = String(songPath.dropFirst(importPath.count + 1))
            let parts = remainder.split(separator: "/", maxSplits: 1)
            guard parts.count >= 2 else { continue }   // skip root-level files
            let name = String(parts[0])
            if groups[name] == nil {
                groups[name] = (importDir.appendingPathComponent(name), [])
            }
            groups[name]!.songs.append(song)
        }

        return groups
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { LocalFolderGroup(id: $0.key, dirURL: $0.value.url, songs: $0.value.songs) }
    }

    // MARK: - Public API

    /// Add a folder from a URL obtained via .fileImporter / UIDocumentPickerViewController.
    func addFolder(url: URL) throws {
        appLog("addFolder: \(url.lastPathComponent)", category: "library")
        // On iOS, startAccessingSecurityScopedResource() must be called before
        // creating a bookmark so the sandbox grants access.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // .minimalBookmark is the correct option on iOS (withSecurityScope is macOS-only).
        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
        } catch {
            appError("addFolder bookmark creation failed for \(url.lastPathComponent): \(error)", category: "library")
            throw error
        }

        let folder = WatchedFolder(
            id: UUID(),
            displayName: url.lastPathComponent,
            bookmarkData: bookmarkData,
            lastScannedAt: Date(),
            trackCount: 0
        )

        guard !watchedFolders.contains(where: {
            $0.displayName == folder.displayName && $0.bookmarkData == folder.bookmarkData
        }) else {
            appLog("addFolder: skipped duplicate \(url.lastPathComponent)", category: "library")
            return
        }

        watchedFolders.append(folder)
        saveBookmarks()
        appLog("addFolder: added \(url.lastPathComponent) (total: \(watchedFolders.count))", category: "library")
    }

    func removeFolder(id: UUID) {
        let name = watchedFolders.first(where: { $0.id == id })?.displayName ?? id.uuidString
        watchedFolders.removeAll { $0.id == id }
        saveBookmarks()
        appLog("removeFolder: removed \(name)", category: "library")
    }

    func updateTrackCount(_ count: Int, for id: UUID) {
        guard let index = watchedFolders.firstIndex(where: { $0.id == id }) else { return }
        watchedFolders[index].trackCount = count
        watchedFolders[index].lastScannedAt = Date()
        saveBookmarks()
    }

    /// Resolve all persisted bookmarks and return valid accessible URLs.
    /// Each returned URL has `startAccessingSecurityScopedResource()` already called;
    /// callers must call `stopAccessingSecurityScopedResource()` when done.
    func resolveAll() -> [URL] {
        appLog("resolveAll: resolving \(watchedFolders.count) folder bookmark(s)", category: "library")
        var valid: [URL] = []
        var staleIDs: [UUID] = []

        for folder in watchedFolders {
            var isStale = false
            // iOS: use no bookmark-resolution options (withSecurityScope is macOS-only)
            guard let resolved = try? URL(
                resolvingBookmarkData: folder.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                appWarn("resolveAll: bookmark resolution failed for \(folder.displayName) — marking stale", category: "library")
                staleIDs.append(folder.id)
                continue
            }

            if isStale {
                appLog("resolveAll: stale bookmark for \(folder.displayName), attempting refresh", category: "library")
                // Try to refresh the bookmark while we still have access.
                let didAccess = resolved.startAccessingSecurityScopedResource()
                let fresh = try? resolved.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                if didAccess { resolved.stopAccessingSecurityScopedResource() }

                if let fresh, let idx = watchedFolders.firstIndex(where: { $0.id == folder.id }) {
                    watchedFolders[idx].bookmarkData = fresh
                    saveBookmarks()
                    appLog("resolveAll: refreshed bookmark for \(folder.displayName)", category: "library")
                } else {
                    appWarn("resolveAll: could not refresh bookmark for \(folder.displayName) — removing", category: "library")
                    staleIDs.append(folder.id)
                    continue
                }
            }

            // Call startAccessingSecurityScopedResource() regardless — it's a no-op for
            // URLs already within the app's sandbox, and activates access for out-of-sandbox
            // URLs obtained via document picker. Only exclude the URL if it doesn't exist.
            _ = resolved.startAccessingSecurityScopedResource()
            if FileManager.default.fileExists(atPath: resolved.path) {
                valid.append(resolved)
            } else {
                appWarn("resolveAll: path no longer exists for \(folder.displayName)", category: "library")
                staleIDs.append(folder.id)
            }
        }

        if !staleIDs.isEmpty {
            appWarn("resolveAll: removing \(staleIDs.count) stale folder(s)", category: "library")
            watchedFolders.removeAll { staleIDs.contains($0.id) }
            saveBookmarks()
        }
        appLog("resolveAll: \(valid.count)/\(watchedFolders.count + staleIDs.count) folders resolved", category: "library")
        return valid
    }

    // MARK: - Folder Structure Backup (item 3)

    /// Builds the payload pushed to `PUT /user/folder-backups`: for each watched
    /// folder that resolves to a path under the app's Documents directory, its
    /// path relative to Documents plus the songs (from `songs`, typically
    /// `LibraryManager.allSongs`) whose file URL lives inside that folder.
    ///
    /// Folders outside Documents (e.g. picked via the Files app from iCloud
    /// Drive/another app's sandbox) are skipped — their contents aren't
    /// recoverable into "this install's Documents" in any meaningful way, and
    /// the security-scoped bookmark wouldn't survive a reinstall anyway.
    func folderBackupEntries(songs: [Song]) -> [FolderBackupEntry] {
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let docsPath = docsDir.standardizedFileURL.path

        var entries: [FolderBackupEntry] = []
        for folder in watchedFolders {
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: folder.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            let folderPath = resolved.standardizedFileURL.path
            guard folderPath.hasPrefix(docsPath) else { continue }

            var relative = String(folderPath.dropFirst(docsPath.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }

            // Songs whose file lives inside this folder (recursively).
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            let tracks: [FolderBackupTrack] = songs.compactMap { song -> FolderBackupTrack? in
                guard let url = song.url else { return nil }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { return nil }
                return FolderBackupTrack(
                    filename: url.lastPathComponent,
                    title: song.title,
                    artist: song.artist,
                    durationSeconds: song.duration,
                    sourceTrackID: song.sourceTrackID
                )
            }

            entries.append(FolderBackupEntry(folderPath: relative, tracks: tracks))
        }
        return entries
    }

    /// Recreates `relativePath` (relative to Documents) as an empty directory
    /// under Documents, returning the resulting URL on success. Used during
    /// "restore my folders" — track files are then redownloaded/placed into
    /// the returned directory by the caller.
    func recreateFolder(relativePath: String) -> URL? {
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let target = docsDir.appendingPathComponent(relativePath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        } catch {
            appError("recreateFolder: failed to create \(relativePath): \(error.localizedDescription)", category: "library")
            return nil
        }
    }

    // MARK: - Persistence

    private func saveBookmarks() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(watchedFolders), forKey: Self.bookmarksKey)
        } catch {
            appError("saveBookmarks encode failed: \(error)", category: "library")
        }
    }

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarksKey) else { return }
        do {
            watchedFolders = try JSONDecoder().decode([WatchedFolder].self, from: data)
            appLog("loadBookmarks: restored \(watchedFolders.count) folder(s)", category: "library")
        } catch {
            appError("loadBookmarks decode failed: \(error)", category: "library")
        }
    }
}
