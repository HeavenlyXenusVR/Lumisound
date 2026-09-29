import Foundation
import UIKit

// MARK: - PlayHistoryStore
//
// Records play counts + last-played timestamps per song, keyed by `Song.id`.
// Exists as its own persisted store (mirroring `DownloadLedgerStore`'s
// shape) rather than fields on `Song` itself, because `LibraryManager`
// re-scans `MPMediaLibrary`/local folders fresh on every launch — anything
// stored only on the in-memory `Song` struct would be wiped every time.
// `Song.id` is stable across rescans on the same device (Apple's
// `MPMediaItem.persistentID` for library items, a Documents-relative-path
// key for imported files — see `DocumentImportService`), so it's a safe key
// for this kind of side-table.

struct PlayHistoryEntry: Codable {
    var playCount: Int = 0
    var lastPlayedAt: Date?
}

@MainActor
final class PlayHistoryStore {
    static let shared = PlayHistoryStore()

    private let key = "playHistory.v1"
    private(set) var entries: [String: PlayHistoryEntry] = [:]

    /// Saves are coalesced (see `save()`) and encoded on this serial queue,
    /// so they stay in order and off the main thread.
    private static let saveQueue = DispatchQueue(label: "PlayHistoryStore.save", qos: .utility)
    private var pendingSave: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?

    private init() {
        load()
        // Write any coalesced save straight away when the app backgrounds,
        // so a pending play count isn't lost if iOS then ends the app.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Call when a song starts playing. Increments its play count and
    /// stamps the current time as its last-played date.
    func recordPlay(songID: String) {
        guard !songID.isEmpty else { return }
        var entry = entries[songID] ?? PlayHistoryEntry()
        entry.playCount += 1
        entry.lastPlayedAt = Date()
        entries[songID] = entry
        save()
    }

    func playCount(for songID: String) -> Int {
        entries[songID]?.playCount ?? 0
    }

    func lastPlayedAt(for songID: String) -> Date? {
        entries[songID]?.lastPlayedAt
    }

    /// Merges play-history entries pulled from the account backup (see
    /// `AccountService.pullSync`) — for each song, keeps the higher play
    /// count and the more recent last-played date, so restoring on a new
    /// device (or after a reinstall) never regresses stats this device
    /// already has.
    func mergeFromSync(_ remote: [String: PlayHistoryEntry]) {
        var changed = false
        for (songID, remoteEntry) in remote {
            var local = entries[songID] ?? PlayHistoryEntry()
            if remoteEntry.playCount > local.playCount {
                local.playCount = remoteEntry.playCount
                changed = true
            }
            if let remoteDate = remoteEntry.lastPlayedAt,
               remoteDate > (local.lastPlayedAt ?? .distantPast) {
                local.lastPlayedAt = remoteDate
                changed = true
            }
            entries[songID] = local
        }
        if changed { save() }
    }

    /// Migrates a play-history entry to a new key — used when a song's
    /// stable ID changes as a side effect of an in-place file rename (e.g.
    /// `LumisoundExclusiveExtensionService`'s extension conversion), so play
    /// count/last-played survive the rename instead of silently resetting.
    func rekey(from oldID: String, to newID: String) {
        guard oldID != newID, let entry = entries[oldID] else { return }
        entries[newID] = entry
        entries[oldID] = nil
        save()
    }

    /// Removes history for songs no longer in the library, so the store
    /// doesn't grow forever with entries for deleted/renamed files. Safe to
    /// call periodically (e.g. after a library scan) with the current set
    /// of song IDs.
    func pruneEntries(keeping validIDs: Set<String>) {
        let before = entries.count
        entries = entries.filter { validIDs.contains($0.key) }
        if entries.count != before { save() }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: PlayHistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    /// Coalesces writes: every play, merge and rekey used to JSON-encode the
    /// whole table (one entry per song ever played) on the main thread and
    /// rewrite it into UserDefaults — a batch rename after a library cleanup
    /// did that once per song. Now changes within a second share one write,
    /// encoded off the main thread.
    private func save() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = entries
        let key = self.key
        Self.saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
