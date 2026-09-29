import SwiftUI
import UniformTypeIdentifiers

extension StreamSearchView {

    // MARK: — Helpers

    /// Groups `streaming.searchResults` into per-source sections, preserving the
    /// order in which each source's first result appears (so a single-source
    /// search shows one section, and a mixed-source playlist resolve shows
    /// "YouTube" / "SoundCloud" sections in result order).
    var groupedResults: [(source: String, tracks: [StreamTrack])] {
        var order: [String] = []
        var buckets: [String: [StreamTrack]] = [:]
        for track in streaming.searchResults {
            if buckets[track.source] == nil {
                buckets[track.source] = []
                order.append(track.source)
            }
            buckets[track.source]?.append(track)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Songs already on this device whose title/artist/album match `searchText`
    /// — shown at the top of the "My Library" tab so on-device tracks actually
    /// surface in search instead of only the server-uploaded library.
    func computeMatchingLocalSongs() -> [Song] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return library.allSongs.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.album.lowercased().contains(q)
        }
    }

    /// Server-recorded download history entries matching `searchText` that
    /// aren't already present on this device — surfaced as "Previously
    /// Downloaded" so the user can re-download tracks they've lost (reinstall,
    /// corruption cleanup, etc.) without re-searching from scratch.
    func computeMatchingDownloadHistory() -> [DownloadHistoryTrack] {
        guard !searchText.isEmpty else { return [] }
        let localIDs = Set(library.allSongs.compactMap { $0.sourceTrackID })
        return streaming.downloadHistory.filter { !localIDs.contains($0.sourceTrackID) }
    }

    /// Key for `refreshLibraryMatches()` — changes when the query, the
    /// library or the download history does.
    var libraryMatchKey: String {
        "\(searchText)|\(library.allSongs.count)|\(streaming.downloadHistory.count)"
    }

    /// Recomputes the cached "On This Device" / "Previously Downloaded"
    /// matches. These used to be computed properties read several times per
    /// render — each read lowercased and scanned the whole library (and
    /// rebuilt a Set of every song's source ID), on every keystroke and every
    /// player tick. Now it runs once per change, debounced while typing.
    func refreshLibraryMatches() async {
        if !searchText.isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
        }
        matchingLocalSongs = computeMatchingLocalSongs()
        matchingDownloadHistory = computeMatchingDownloadHistory()
    }

    func sourceLabel(_ src: String) -> String {
        switch src {
        case "youtube":    return "YouTube"
        case "soundcloud": return "SoundCloud"
        case "server":     return "Server"
        case "my":         return "My Library"
        default:           return src.capitalized
        }
    }

    /// SF Symbol for each source tab — used by the pill selector so each tab
    /// carries an at-a-glance icon instead of text alone.
    func sourceIcon(_ src: String) -> String {
        switch src {
        case "youtube":    return "play.rectangle.fill"
        case "soundcloud": return "cloud.fill"
        case "server":     return "externaldrive.fill"
        case "my":         return "person.crop.circle.fill"
        default:           return "magnifyingglass"
        }
    }

    /// Human-readable "how long ago" text for `trendingLastUpdated`, used by
    /// the trending header's staleness indicator. Deliberately coarse (no
    /// live-ticking timer) — good enough to tell "just fetched" from "this is
    /// old, tap refresh" without adding a repeating timer to the view.
    var trendingUpdatedText: String {
        guard let last = trendingLastUpdated else { return "" }
        let seconds = Int(Date().timeIntervalSince(last))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "Updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        let days = hours / 24
        return "Updated \(days)d ago"
    }

    func triggerSearch() {
        failedTrackIDs.removeAll()
        appBreadcrumb("Searched \"\(searchText)\" [source: \(selectedSource)]")
        if selectedSource == "server" {
            Task { await streaming.searchServerLibrary(query: searchText) }
        } else if selectedSource == "my" {
            guard let token = account.token else { return }
            Task { await streaming.fetchUserMusic(token: token, search: searchText) }
            Task { await streaming.fetchDownloadHistory(token: token, search: searchText) }
        } else if StreamingService.isSpotifyURL(searchText) {
            Task { await streaming.resolveSpotify(url: searchText, existingSongs: library.allSongs) }
        } else if StreamingService.isPlaylistURL(searchText) {
            Task { await streaming.resolvePlaylist(url: searchText, existingSongs: library.allSongs) }
        } else {
            Task { await streaming.search(query: searchText, source: selectedSource) }
        }
    }
}
