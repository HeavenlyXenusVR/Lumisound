import Foundation

/// Persists `(mtime, fileSize) → Song` mappings on disk so repeated library scans
/// skip AVURLAsset metadata extraction for unchanged files.
/// Must be accessed on @MainActor (mirrors LibraryManager's actor isolation).
@MainActor
final class ScanCacheService {
    static let shared = ScanCacheService()

    struct CacheEntry: Codable {
        let mtime: TimeInterval
        let fileSize: Int64
        let song: Song
    }

    /// File `(mtime, size)` — the cheap, hashable identity used to detect changed files
    /// without re-running expensive `AVURLAsset` metadata extraction.
    struct FileStamp: Hashable {
        let mtime: TimeInterval
        let size: Int64
    }

    private var entries: [String: CacheEntry] = [:]
    private let cacheURL: URL
    /// Set by `store()`/`evictMissing()`, cleared by `persist()`. Without this,
    /// `persist()` re-encodes and rewrites the ENTIRE cache (hundreds/800+
    /// entries, each a full `Song`) every time it's called — and it's called
    /// on a timer every 3 and 10 minutes (`LibraryManager+PeriodicMetadataRefresh`,
    /// `+MetadataReEnrichment`) regardless of whether anything actually
    /// changed. At a large library size that's a real, recurring cost for
    /// zero benefit on the (common) ticks where nothing was touched.
    private var dirty = false

    private init() {
        // .cachesDirectory essentially never fails to resolve on a real device,
        // but this singleton is created during the library scan launch path —
        // a force-unwrap crash here would take down the app on nearly every
        // cold start. Fall back to temporaryDirectory (always available).
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // v4: keys switched from absolute paths (which embed the sandbox container
        // UUID and change on every reinstall) to Documents-relative paths. Bumping
        // the filename starts from a clean slate instead of accumulating dead v3
        // entries keyed on paths that can never match again.
        cacheURL = caches.appendingPathComponent("library_scan_cache_v4.json")
        load()
    }

    /// Reads `(mtime, size)` for `url` directly from the filesystem.
    ///
    /// This performs a blocking `stat()` syscall — callers scanning many files
    /// MUST run this off the main actor (e.g. inside `Task.detached`) so a large
    /// library scan doesn't stall the UI with thousands of serial syscalls.
    nonisolated static func fileStamp(for url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              let mdate = attrs[.modificationDate] as? Date
        else { return nil }
        return FileStamp(mtime: mdate.timeIntervalSince1970, size: size)
    }

    /// Path relative to the app's Documents directory, if `url` lies within it.
    ///
    /// Sideloaded installs (e.g. via AltStore) get a brand-new sandbox container
    /// UUID on every update/reinstall, so the absolute path
    /// `.../Containers/Data/Application/<UUID>/Documents/...` changes completely
    /// even though the file itself didn't move. Keying on the absolute path made
    /// every cache entry miss on every update — forcing a full re-scan (and
    /// re-extraction of metadata) of the entire library, which is the dominant
    /// cause of the "freakout"/huge performance hit users see right after
    /// installing an update. The portion of the path *after* "Documents" is
    /// stable across reinstalls and is what we key on instead.
    nonisolated static func documentsRelativePath(for url: URL) -> String? {
        guard url.isFileURL,
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let docsPath = docs.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(docsPath) else { return nil }
        return String(filePath.dropFirst(docsPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Returns the cached `Song` for `url` if `stamp` matches the stored entry.
    /// Pure in-memory dictionary lookup — no I/O, safe to call on the main actor.
    ///
    /// The returned song's `url` is re-anchored to `url` (the freshly-enumerated,
    /// guaranteed-current path) rather than whatever absolute path was stored at
    /// cache-write time — that stored path may belong to a previous app install's
    /// sandbox container and no longer resolve to a real file.
    func cachedSong(for url: URL, stamp: FileStamp) -> Song? {
        guard let entry = entries[Self.stableKey(for: url)],
              entry.mtime == stamp.mtime,
              entry.fileSize == stamp.size
        else { return nil }
        var song = entry.song
        song.url = url
        return song
    }

    /// A copy of the current cache, for callers that need to look up many
    /// entries at once off the main actor (see `LibraryManager
    /// .resolveSongs`'s `scan.cacheLookup` section). `[String: CacheEntry]`
    /// is a value type with copy-on-write storage, so this is an O(1)
    /// reference-count bump, not an O(n) copy — cheap enough to call on
    /// every scan despite returning what can be a many-thousand-entry dict.
    func snapshotEntries() -> [String: CacheEntry] {
        entries
    }

    /// Stores a `Song` for `url` keyed on the given `(mtime, size)` stamp.
    /// Pure in-memory dictionary write — no I/O, safe to call on the main actor.
    func store(song: Song, for url: URL, stamp: FileStamp) {
        entries[Self.stableKey(for: url)] = CacheEntry(mtime: stamp.mtime, fileSize: stamp.size, song: song)
        dirty = true
    }

    /// Writes the in-memory cache to disk atomically. Call once after a bulk scan completes.
    /// Encoding/writing thousands of entries is offloaded to a background task so it
    /// never blocks the main thread. No-op if nothing has changed since the last
    /// persist (see `dirty`) — safe to call this liberally/on a timer.
    func persist() {
        guard dirty else { return }
        dirty = false
        let snapshot = entries
        let destination = cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    /// Removes cache entries for paths that no longer exist on disk.
    /// Keys are now Documents-relative (see `documentsRelativePath`), so they
    /// must be re-anchored to the current sandbox before checking existence —
    /// `fileExists(atPath:)` on a bare relative key would resolve against the
    /// process's working directory and incorrectly evict everything.
    func evictMissing() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let before = entries.count
        entries = entries.filter { key, _ in
            let candidate = key.hasPrefix("/") ? key : docs.appendingPathComponent(key).path
            return FileManager.default.fileExists(atPath: candidate)
        }
        if entries.count != before { dirty = true }
    }

    /// `nonisolated static` — this only calls the `nonisolated static`
    /// `documentsRelativePath(for:)` and reads `url` itself, never touching
    /// `entries`/`dirty`, so it's safe to call from a detached task (see
    /// `snapshotEntries()`'s caller in `LibraryManager+ScanCacheHelper.swift`)
    /// without hopping back to the main actor per lookup.
    nonisolated static func stableKey(for url: URL) -> String {
        // Prefer the sandbox-relative path (survives reinstalls); fall back to
        // the absolute path for files outside Documents (e.g. external folders
        // accessed via security-scoped bookmarks, which have their own
        // per-install staleness handled at the bookmark layer).
        Self.documentsRelativePath(for: url) ?? url.standardizedFileURL.path
    }

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return }
        entries = decoded
    }
}
