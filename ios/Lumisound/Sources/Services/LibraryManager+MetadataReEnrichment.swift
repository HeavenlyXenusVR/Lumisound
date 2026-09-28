import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    // MARK: - Periodic Metadata Re-Enrichment

    /// Call once on app launch. Re-checks imported songs with missing
    /// artist/album/genre/year every 10 minutes and tries to fill them in via
    /// `MetadataFetchService`.
    ///
    /// Covers the case where a user deletes and reinstalls the app, then
    /// copies their music back from a backup folder: the reinstall wipes
    /// `EnrichmentCacheStore`'s `UserDefaults` cache, but more importantly the
    /// very first scan after a mass file-copy can race with the filesystem
    /// (or simply hit a transient network failure during the iTunes/MusicBrainz/
    /// Deezer lookups in `DocumentImportService.makeSong`), leaving tracks
    /// permanently stuck with blank metadata since nothing ever re-checks them
    /// afterward. This sweep gives those tracks repeated chances to fill in.
    func startPeriodicMetadataReenrichment() {
        guard metadataReenrichTimer == nil else { return }

        Task { await reenrichSongsMissingMetadata() }

        let interval: TimeInterval = 10 * 60
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Skip the network-bound online metadata lookups while backgrounded —
                // pointless radio/CPU use when the user isn't viewing the library.
                guard UIApplication.shared.applicationState == .active else { return }
                await self?.reenrichSongsMissingMetadata()
            }
        }
        // Lets iOS batch this wake-up with others (battery).
        timer.tolerance = (interval) * 0.1
        RunLoop.main.add(timer, forMode: .common)
        metadataReenrichTimer = timer
    }

    /// Finds locally-imported songs missing artist, album, genre, or year and
    /// tries to fill them in via the online metadata lookup chain. Updates
    /// `importedSongs`, the on-disk scan cache, and the enrichment cache so
    /// successful lookups persist across future scans/restarts.
    func reenrichSongsMissingMetadata() async {
        guard !isReenrichingMetadata else { return }
        let candidates = importedSongs.enumerated().filter { _, song in
            song.artist.isEmpty || song.album.isEmpty || song.genre.isEmpty || song.year.isEmpty
        }
        guard !candidates.isEmpty else { return }

        isReenrichingMetadata = true
        defer { isReenrichingMetadata = false }

        appLog("Periodic metadata re-enrichment: checking \(candidates.count) song(s)", category: "library")

        var updatedCount = 0
        for (index, song) in candidates {
            guard index < importedSongs.count, importedSongs[index].id == song.id else { continue }

            let enriched = await MetadataFetchService.shared.enrich(song: song)
            guard enriched.artist != song.artist || enriched.album != song.album
                || enriched.genre != song.genre || enriched.year != song.year
            else { continue }

            importedSongs[index] = enriched
            updatedCount += 1

            if let url = enriched.url, let stamp = ScanCacheService.fileStamp(for: url) {
                ScanCacheService.shared.store(song: enriched, for: url, stamp: stamp)
            }
            if let filename = enriched.url?.lastPathComponent {
                var entry: [String: String] = [:]
                if !enriched.artist.isEmpty { entry["artist"] = enriched.artist }
                if !enriched.album.isEmpty  { entry["album"]  = enriched.album  }
                if !enriched.genre.isEmpty  { entry["genre"]  = enriched.genre  }
                if !enriched.year.isEmpty   { entry["year"]   = enriched.year   }
                await EnrichmentCacheStore.shared.store(filename, entry: entry)
            }
        }

        guard updatedCount > 0 else { return }

        appLog("Periodic metadata re-enrichment: updated \(updatedCount) song(s)", category: "library")
        // One event per sweep, not per candidate — `candidates` can be a
        // large fraction of the library on a fresh install/restore.
        RemoteLogger.log(category: "sync", event: "metadata_reenrichment_batch",
                          detail: ["checked": candidates.count, "updated": updatedCount])
        ScanCacheService.shared.persist()
        await EnrichmentCacheStore.shared.persist()
        rebuildAllSongs()
    }
}
