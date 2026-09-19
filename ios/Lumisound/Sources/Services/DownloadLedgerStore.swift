import Foundation

// MARK: - DownloadLedgerStore
//
// Records the source id (LUMISOUND_ID form, "<source>:<id>") of every track the
// app downloads → the resulting filename, so duplicate detection never depends
// on reading the id tag back out of the file afterwards.
//
// Why this exists: m4a (the default download format) was silently dropping the
// LUMISOUND_ID metadata tag, so a re-downloaded playlist couldn't recognise the
// tracks already on disk and re-fetched them. The bridge now embeds the id
// correctly for new downloads, but this ledger is the authoritative, format- and
// AVFoundation-independent record of "we have this source track" for everything
// the app downloads. Entries are always validated against the files actually
// present (callers pass the current set of library filenames), so deleting a
// file naturally re-enables downloading it again.

@MainActor
final class DownloadLedgerStore {
    static let shared = DownloadLedgerStore()

    private let key = "downloadLedger.v1"
    private(set) var map: [String: String] = [:]   // sourceTrackID -> filename

    private init() { load() }

    /// Records that `sourceTrackID` is present on disk as `filename`.
    func record(sourceTrackID: String, filename: String) {
        guard !sourceTrackID.isEmpty, !filename.isEmpty else { return }
        // Having the file contradicts "this track is unavailable", so forget any
        // remembered failure for it (see DownloadFailureStore). Done here rather
        // than at each of the six call sites that record a ledger entry: this is
        // the app's single "we now have this track" signal, so a future success
        // path cannot forget to clear the suppression and leave a track that
        // demonstrably works sitting in a month-long cool-off.
        DownloadFailureStore.shared.clear(sourceTrackID: sourceTrackID)
        if map[sourceTrackID] == filename { return }
        map[sourceTrackID] = filename
        save()
    }

    /// The filename recorded for a source id, if any.
    func filename(for sourceTrackID: String) -> String? { map[sourceTrackID] }

    /// True if this source id was downloaded and its file is still present
    /// (its recorded filename appears in `presentFilenames`).
    func isPresent(_ sourceTrackID: String, presentFilenames: Set<String>) -> Bool {
        guard let fn = map[sourceTrackID] else { return false }
        return presentFilenames.contains(fn)
    }

    /// All recorded source ids whose files are still present on disk.
    func presentSourceIDs(presentFilenames: Set<String>) -> [String] {
        map.compactMap { presentFilenames.contains($0.value) ? $0.key : nil }
    }

    // MARK: - In-flight download guard
    //
    // `downloadToLibrary`'s pre-download dedupe (an `existingSongs` snapshot
    // plus this store's completed-download `map`) only catches a track
    // that's ALREADY on disk. It does nothing for two downloads of the same
    // sourceTrackID that start close together and are both still in
    // progress — exactly what happens when `TrackedPlaylistStore
    // .runAutoDownloads` gets triggered from two independent, uncoordinated
    // sites (app launch/foreground, and a `BGAppRefreshTask` handler) that
    // can each be a SEPARATE PROCESS instance: iOS frequently terminates
    // the process after a background-refresh task completes rather than
    // just suspending it, so the in-memory `isRunningAutoDownloads` flag
    // (also process-local) provides no protection across that boundary —
    // both processes independently scan the same "missing" tracks and both
    // start downloading them before either has written anything to disk.
    // Backed by UserDefaults (not just an in-memory Set) specifically so it
    // survives that process boundary. Self-expiring via `_inFlightTTL` in
    // case a process is killed mid-download without ever calling
    // `endDownload` — a stale entry would otherwise block that track from
    // ever being (re)downloaded again.
    private let inFlightKey = "downloadLedger.inFlight.v1"
    private let inFlightTTL: TimeInterval = 5 * 60

    /// Attempts to claim `sourceTrackID` for download. Returns `true` (and
    /// records the claim) if nothing else currently holds it; `false` if
    /// another in-flight download already claimed it recently — the caller
    /// should skip starting a redundant download. MUST be paired with
    /// `endDownload(sourceTrackID:)` once the download finishes (success OR
    /// failure) so the claim doesn't outlive it unnecessarily.
    func beginDownload(sourceTrackID: String) -> Bool {
        guard !sourceTrackID.isEmpty else { return true }
        var inFlight = loadInFlight()
        let now = Date().timeIntervalSince1970
        if let claimedAt = inFlight[sourceTrackID], now - claimedAt < inFlightTTL {
            return false
        }
        inFlight[sourceTrackID] = now
        saveInFlight(inFlight)
        return true
    }

    /// Releases a claim made by `beginDownload`. Safe to call even if the
    /// claim was never held (e.g. `beginDownload` returned `false`) or has
    /// already expired.
    func endDownload(sourceTrackID: String) {
        guard !sourceTrackID.isEmpty else { return }
        var inFlight = loadInFlight()
        inFlight.removeValue(forKey: sourceTrackID)
        saveInFlight(inFlight)
    }

    private func loadInFlight() -> [String: TimeInterval] {
        guard let data = UserDefaults.standard.data(forKey: inFlightKey),
              let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveInFlight(_ inFlight: [String: TimeInterval]) {
        if let data = try? JSONEncoder().encode(inFlight) {
            UserDefaults.standard.set(data, forKey: inFlightKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
