import Foundation
import UIKit

extension StreamingService {

    // MARK: - Convert ServerTrack to Song

    /// Wraps a `ServerTrack` in a `Song` so it can be handed to `AudioPlayerManager`.
    /// The stream URL is baked in; artwork is loaded lazily via `ArtworkService` using
    /// the server artwork URL as the cache key.
    func toSong(serverTrack: ServerTrack) -> Song {
        let artworkKey = serverArtworkURL(for: serverTrack)?.absoluteString
        var headers: [String: String] = [:]
        // "Bearer " prefix REQUIRED — see the identical fix in
        // StreamingService+ConvertToSong.swift. The bridge's `check_auth`
        // rejects a bare key with 401 before comparing it at all.
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        if let token = AccountService.shared?.token, !token.isEmpty {
            headers["X-Account-Token"] = token
        }
        return Song(
            id: serverTrack.id,
            title: serverTrack.title,
            artist: serverTrack.artist,
            album: serverTrack.album,
            duration: serverTrack.duration,
            url: serverStreamURL(for: serverTrack),
            persistentID: nil,
            artworkCacheKey: artworkKey,
            trackNumber: Int(serverTrack.trackNumber) ?? 0,
            year: "",
            genre: serverTrack.genre,
            bitrate: 0,
            sampleRate: 0,
            httpHeaders: headers.isEmpty ? nil : headers
        )
    }
}
