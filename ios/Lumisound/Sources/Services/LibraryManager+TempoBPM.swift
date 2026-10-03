import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    // MARK: - Tempo (BPM)

    /// Returns `song.bpm` if already known, otherwise analyzes the track via
    /// `BPMAnalyzerService` (on-device, ffmpeg-equivalent autocorrelation) and
    /// caches the result on the song for future lookups — used by the player
    /// to drive beat-aware crossfades and by any other tempo-aware feature.
    /// Returns `nil` if the song has no local URL or no tempo could be estimated.
    func bpm(for song: Song) async -> Double? {
        if let bpm = song.bpm { return bpm }
        guard let url = song.url else { return nil }

        guard let estimated = await BPMAnalyzerService.shared.bpm(for: url) else { return nil }
        storeBPM(estimated, for: song.id)
        return estimated
    }

    /// Writes a freshly-analyzed BPM back into `mediaSongs`/`importedSongs` so
    /// it's returned instantly next time and survives in the persisted
    /// library snapshot.
    func storeBPM(_ bpm: Double, for songID: String) {
        if let index = mediaSongs.firstIndex(where: { $0.id == songID }) {
            mediaSongs[index].bpm = bpm
        } else if let index = importedSongs.firstIndex(where: { $0.id == songID }) {
            importedSongs[index].bpm = bpm
        } else {
            return
        }
        // Patched into the id index at once, so lookups see it immediately,
        // while the full rebuild is batched.
        //
        // Every BPM result used to call `rebuildAllSongs()` directly: a re-sort
        // and re-index of the whole library, a republish that re-rendered every
        // screen observing it, and then a snapshot write. Analysis completes one
        // track at a time, so that was the full cost once per song for as long
        // as analysis ran — a steady source of both UI hitches and heat. Lists
        // do not display BPM, so nothing visible is lost by folding a run of
        // results into one rebuild.
        if var song = songsByID[songID] {
            song.bpm = bpm
            songsByID[songID] = song
        }
        scheduleBatchedRebuild()
    }

    /// Runs `rebuildAllSongs()` once, `batchedRebuildDelay` after the first
    /// request, however many arrive in between.
    func scheduleBatchedRebuild() {
        guard Self.batchedRebuildTask == nil else { return }
        Self.batchedRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.batchedRebuildDelay * 1_000_000_000))
            Self.batchedRebuildTask = nil
            self?.rebuildAllSongs()
        }
    }

    private static var batchedRebuildTask: Task<Void, Never>?
    private static let batchedRebuildDelay: TimeInterval = 30
}
