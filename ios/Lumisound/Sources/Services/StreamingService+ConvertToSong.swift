import Foundation
import UIKit

extension StreamingService {

    // MARK: - Convert to Song

    func toSong(track: StreamTrack, streamURL: URL) -> Song {
        // The player fetches `streamURL` (the bridge proxy) directly, so carry
        // any auth the bridge needs on the Song: the shared API key (if set) and
        // the account token (lets the proxy use this user's YouTube cookies for
        // age-restricted/bot-gated videos).
        var headers: [String: String] = [:]
        // "Bearer " prefix REQUIRED. The bridge's `check_auth` rejects anything
        // that doesn't start with it ("Missing Authorization header", 401)
        // before it ever compares the key, so sending the bare key here meant
        // every streamed track failed auth: AVAudioFile's download got 401 and
        // logged "You're not signed in or don't have permission for this", then
        // the AVPlayer fallback got NSURLErrorUserAuthenticationRequired
        // (-1013) and the track was skipped. Verified against the live bridge —
        // bare key returns 401, `Bearer <key>` returns 206. `makeRequest` (the
        // path every other request goes through) has always sent the prefix;
        // these Song headers are hand-built because the PLAYER fetches the
        // proxy URL directly, which is how they drifted.
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        if let token = AccountService.shared?.token, !token.isEmpty {
            headers["X-Account-Token"] = token
        }
        return Song(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: "",
            duration: track.duration,
            url: streamURL,
            persistentID: nil,
            artworkCacheKey: track.thumbnailURL.isEmpty ? nil : track.thumbnailURL,
            trackNumber: 0,
            year: "",
            genre: "",
            bitrate: 0,
            sampleRate: 0,
            httpHeaders: headers.isEmpty ? nil : headers
        )
    }
}
