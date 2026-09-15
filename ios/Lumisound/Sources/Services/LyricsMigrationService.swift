import Foundation

// MARK: - LyricsMigrationService
//
// Uploads locally-stored lyrics to the account, once.
//
// Lyrics Aria generated before they were persisted server-side were written to
// `Documents/Lyrics/<song id>.lrc` on the phone that asked for them and sent
// nowhere else. That file is currently the only copy in existence: it cannot
// reach tvOS, it does not survive a reinstall, and it never reaches a second
// device. Public lyrics databases do not have these by definition — a track
// being absent from them is the whole reason Aria was asked to transcribe it.
//
// This walks that directory once and submits what it finds, so work already done
// is recovered rather than stranded. Everything generated from now on is stored
// server-side as it is produced, so this is strictly a catch-up pass for the
// backlog.
@MainActor
final class LyricsMigrationService {
    static let shared = LyricsMigrationService()

    /// Song ids already submitted. Keyed per-song rather than a single "done"
    /// flag: a run can be interrupted by the app being closed, and a flag would
    /// either re-upload everything or abandon whatever was left.
    private static let uploadedKey = "lyrics.migration.uploadedSongIDs"
    /// Marks the sweep as finished so a launch with nothing to do costs one
    /// `UserDefaults` read rather than a directory listing.
    private static let completedKey = "lyrics.migration.completed"

    private var isRunning = false

    private var uploaded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.uploadedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.uploadedKey) }
    }

    private var lyricsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
    }

    /// Runs the sweep if there is anything left to do. Safe to call on every
    /// launch.
    func migrateIfNeeded(library: LibraryManager, account: AccountService) {
        guard !isRunning else { return }
        guard !UserDefaults.standard.bool(forKey: Self.completedKey) else { return }
        guard account.isLoggedIn else { return }

        isRunning = true
        Task { [weak self] in
            defer { self?.isRunning = false }
            await self?.run(library: library, account: account)
        }
    }

    private func run(library: LibraryManager, account: AccountService) async {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: lyricsDirectory, includingPropertiesForKeys: nil
        ) else {
            // No directory at all means nothing was ever generated here.
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            return
        }

        let lrcFiles = files.filter { $0.pathExtension.lowercased() == "lrc" }
        guard !lrcFiles.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            return
        }

        var done = uploaded
        var sent = 0
        var skipped = 0

        for file in lrcFiles {
            // The filename is the song id with path-illegal characters replaced,
            // so it cannot be reversed into an id directly — the library is
            // searched for the song whose sanitized id produces this filename.
            let stem = file.deletingPathExtension().lastPathComponent
            guard !done.contains(stem) else { continue }

            guard let song = library.allSongs.first(where: { Self.sanitize($0.id) == stem }) else {
                // The track was removed from the library since. Its lyrics have
                // nothing to attach to, so mark it handled rather than
                // re-scanning it on every launch forever.
                done.insert(stem)
                skipped += 1
                continue
            }

            guard let lrc = try? String(contentsOf: file, encoding: .utf8),
                  !lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                done.insert(stem)
                skipped += 1
                continue
            }

            let ok = await account.submitLyrics(
                title: song.title, artist: song.artist, syncedLyrics: lrc
            )
            if ok {
                done.insert(stem)
                sent += 1
                uploaded = done
            } else {
                // Leave it unmarked so the next launch retries it. A failed
                // upload must not be mistaken for a completed one.
                continue
            }

            // Paced deliberately. This is a background catch-up with no one
            // waiting on it, and a library with hundreds of generated lyrics
            // should not open with a burst of hundreds of requests.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        uploaded = done
        if sent + skipped >= lrcFiles.count {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
        }
        appLog("LyricsMigrationService: \(sent) uploaded, \(skipped) skipped, \(lrcFiles.count) local file(s)",
               category: "sync")
    }

    /// Must match `syncedLyricsURL(for:)` in NowPlayingView+Helpers exactly —
    /// it is what produced these filenames.
    private static func sanitize(_ songID: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return songID.components(separatedBy: illegal).joined(separator: "_")
    }
}
