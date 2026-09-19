import Foundation

// MARK: - DownloadFailureStore
//
// Remembers tracks that cannot be downloaded, so the app stops asking for them
// on every pass.
//
// The auto-download pipeline had no memory of failure at all. Its "do I already
// have this?" filter (see `LibraryManager.hasLocalCopy`) is necessarily about
// files on disk, and a track that never downloads never lands on disk — so every
// pass looked at it, correctly concluded it was missing, and asked for it again.
// Forever. Measured over one week on a real library: 9,842 download attempts
// spread over 2,223 tracks that no longer exist on YouTube, with individual
// tracks re-attempted more than 300 times across six weeks. Nothing about that
// was visible to the user; the tracks simply never appeared.
//
// The cost is not only wasted work. That volume of requests is itself part of
// what provokes YouTube's bot wall, so relentlessly re-asking for dead videos was
// actively degrading the downloads that COULD have worked.
//
// Two decisions shape this:
//
//   1. **Only the bridge decides what is permanent.** A removed video and a bot
//      wall both come back as a 404, so the client cannot tell them apart from
//      the status code, and guessing from the message text would be fragile. The
//      bridge classifies from yt-dlp's own stderr and sends `permanent` (see
//      `_ytdlp_failure_is_permanent`). Nothing here infers it.
//   2. **Suppression expires.** A video that is gone today may be back tomorrow:
//      re-uploaded, un-privated, or unblocked in this region. So a permanent
//      failure earns a growing cool-off rather than a life sentence — which also
//      means a misclassification costs a delay, not a track lost from the
//      library forever.
@MainActor
final class DownloadFailureStore {
    static let shared = DownloadFailureStore()

    private struct Entry: Codable {
        var lastFailed: Date
        /// Consecutive permanent failures. Drives how long to wait before the
        /// next attempt, so a track that keeps failing is asked about less and
        /// less often instead of at a fixed rate.
        var strikes: Int
    }

    private let key = "downloadFailures.v1"
    private var entries: [String: Entry] = [:]

    private init() { load() }

    /// How long to stay quiet after `strikes` consecutive permanent failures.
    ///
    /// The first wait is deliberately short — a day — because the most likely
    /// reason for a single permanent-looking failure is something that really is
    /// temporary but reported badly, and a day costs the user almost nothing.
    /// Repeat offenders stretch out to a month, which for a genuinely deleted
    /// video is effectively "stop asking" while still self-healing if it returns.
    private static func cooloff(strikes: Int) -> TimeInterval {
        switch strikes {
        case ..<1:  return 0
        case 1:     return 24 * 60 * 60        // 1 day
        case 2:     return 3 * 24 * 60 * 60    // 3 days
        case 3:     return 7 * 24 * 60 * 60    // 1 week
        default:    return 30 * 24 * 60 * 60   // 1 month
        }
    }

    /// Whether this track should be left alone for now.
    func shouldSkip(sourceTrackID: String) -> Bool {
        guard !sourceTrackID.isEmpty, let entry = entries[sourceTrackID] else { return false }
        return Date().timeIntervalSince(entry.lastFailed) < Self.cooloff(strikes: entry.strikes)
    }

    /// Records a failure the bridge classified as a property of the video.
    ///
    /// MUST only be called for `permanent` failures. Recording a bot wall or a
    /// timeout here would suppress a whole library's worth of downloadable tracks
    /// for a month on the strength of one bad afternoon — exactly the outcome the
    /// bridge-side classification exists to prevent.
    func recordPermanentFailure(sourceTrackID: String) {
        guard !sourceTrackID.isEmpty else { return }
        var entry = entries[sourceTrackID] ?? Entry(lastFailed: .distantPast, strikes: 0)
        entry.strikes += 1
        entry.lastFailed = Date()
        entries[sourceTrackID] = entry
        save()
    }

    /// Forgets a track's failure history — call on a successful download, so a
    /// track that recovers starts from a clean slate rather than carrying strikes
    /// that would punish it for the next hiccup.
    func clear(sourceTrackID: String) {
        guard entries.removeValue(forKey: sourceTrackID) != nil else { return }
        save()
    }

    /// Tracks currently being held back, for the "N unavailable" summary the user
    /// sees instead of tracks silently never arriving.
    func suppressedCount<S: Sequence>(among sourceTrackIDs: S) -> Int
    where S.Element == String {
        sourceTrackIDs.reduce(into: 0) { $0 += shouldSkip(sourceTrackID: $1) ? 1 : 0 }
    }

    /// Clears every remembered failure — for a user who has fixed the underlying
    /// cause (uploaded fresh cookies, changed region) and wants the app to try
    /// everything again now rather than waiting out the cool-offs.
    func clearAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    var suppressedTotal: Int {
        entries.keys.reduce(into: 0) { $0 += shouldSkip(sourceTrackID: $1) ? 1 : 0 }
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        // Pruned on write rather than on read: an entry whose cool-off has long
        // expired carries no information except a strike count that should not
        // follow a track around for months. Keeps the stored blob bounded on a
        // library where thousands of tracks can fail.
        let cutoff = Date().addingTimeInterval(-Self.cooloff(strikes: .max))
        entries = entries.filter { $0.value.lastFailed > cutoff }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
