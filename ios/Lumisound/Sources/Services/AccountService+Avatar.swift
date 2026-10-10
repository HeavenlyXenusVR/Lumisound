import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Avatar

    /// Upload a profile picture as JPEG (max 1 MB enforced server-side).
    /// Always re-encodes to a static JPEG — used by flows that only ever
    /// hand this a `UIImage` (e.g. a cropped camera photo). For data that
    /// might be an animated GIF (e.g. straight from `PhotosPicker`), use
    /// `uploadAvatarData(_:)` instead so animation isn't lost before upload.
    func uploadAvatar(image: UIImage) async {
        guard isLoggedIn else { return }
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
            appWarn("uploadAvatar: could not encode image as JPEG", category: "account")
            return
        }
        guard var req = makeBaseRequest("/user/avatar", method: "POST") else {
            appWarn("uploadAvatar: could not build request", category: "account")
            return
        }
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = jpeg
        appLog("uploadAvatar: uploading \(jpeg.count / 1024)KB", category: "account")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                appLog("uploadAvatar: success", category: "account")
            } else {
                appWarn("uploadAvatar: HTTP \(status)", category: "account")
            }
        } catch {
            appError("uploadAvatar: \(error.localizedDescription)", category: "account")
        }
        avatarImage = image
        saveAvatarLocally(image)
    }

    /// Upload avatar image data straight from the picker, preserving
    /// animation when it's a GIF. `UIImage(data:)` only ever decodes a GIF's
    /// first frame, so this checks `isGIFData` on the *raw bytes* before any
    /// UIImage conversion happens — decoding first (like `uploadAvatar(image:)`
    /// does) would silently flatten the animation before it ever reached this
    /// method. Non-GIF data falls back to the existing JPEG re-encode path.
    func uploadAvatarData(_ data: Data) async {
        guard isLoggedIn else { return }
        guard isGIFData(data) else {
            // Not a GIF — decode + re-encode as JPEG, same as before.
            guard let image = UIImage(data: data) else {
                appWarn("uploadAvatarData: could not decode image data", category: "account")
                return
            }
            await uploadAvatar(image: image)
            return
        }

        guard data.count <= 15_728_640 else {
            appWarn("uploadAvatarData: GIF exceeds 15MB limit (\(data.count / 1024)KB)", category: "account")
            errorMessage = "GIF avatars must be under 15MB."
            return
        }
        guard let animated = await UIImage.gifImageAsync(data: data) else {
            appWarn("uploadAvatarData: could not decode GIF data", category: "account")
            return
        }
        guard var req = makeBaseRequest("/user/avatar", method: "POST") else {
            appWarn("uploadAvatarData: could not build request", category: "account")
            return
        }
        req.setValue("image/gif", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        appLog("uploadAvatarData: uploading GIF \(data.count / 1024)KB", category: "account")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                appLog("uploadAvatarData: success", category: "account")
            } else {
                appWarn("uploadAvatarData: HTTP \(status)", category: "account")
            }
        } catch {
            appError("uploadAvatarData: \(error.localizedDescription)", category: "account")
        }
        avatarImage = animated
        saveGIFAvatarLocally(data)
    }

    /// Load avatar from local cache first, then from server. Updates `avatarImage`.
    func loadAvatar(forceRefresh: Bool = false) async {
        if !forceRefresh, let cached = loadAvatarLocally() {
            avatarImage = cached
            appLog("loadAvatar: loaded from local cache", category: "account")
            return
        }
        guard isLoggedIn, let userId = currentUser?.id else { return }
        guard let req = makeBaseRequest("/user/avatar/\(userId)", method: "GET") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                appWarn("loadAvatar: HTTP \(status)", category: "account")
                return
            }
            if isGIFData(data) {
                guard let animated = await UIImage.gifImageAsync(data: data) else {
                    appWarn("loadAvatar: invalid GIF data", category: "account")
                    return
                }
                avatarImage = animated
                saveGIFAvatarLocally(data)
            } else {
                guard let img = UIImage(data: data) else {
                    appWarn("loadAvatar: invalid image data", category: "account")
                    return
                }
                avatarImage = img
                saveAvatarLocally(img)
            }
            appLog("loadAvatar: fetched from server (\(data.count / 1024)KB)", category: "account")
        } catch {
            appWarn("loadAvatar: \(error.localizedDescription)", category: "account")
        }
    }

    func makeBaseRequest(_ path: String, method: String) -> URLRequest? {
        let base = bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static var localGIFAvatarURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("user_avatar.gif")
    }

    private static var localJPEGAvatarURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("user_avatar.jpg")
    }

    func saveAvatarLocally(_ image: UIImage) {
        // Clear any stale GIF cache — otherwise a user who switches from an
        // animated avatar back to a static one would keep seeing the old
        // animated file on next launch (loadAvatarLocally prefers .gif).
        if let gifURL = Self.localGIFAvatarURL {
            try? FileManager.default.removeItem(at: gifURL)
        }
        guard let url = Self.localJPEGAvatarURL else { return }
        image.jpegData(compressionQuality: 0.8).flatMap { try? $0.write(to: url) }
    }

    /// Caches the raw GIF bytes as-is (never re-encoded — re-encoding through
    /// UIImage/jpegData would collapse it back to a single frame). Clears any
    /// stale static-JPEG cache for the same reason `saveAvatarLocally` clears
    /// the GIF one.
    func saveGIFAvatarLocally(_ data: Data) {
        if let jpegURL = Self.localJPEGAvatarURL {
            try? FileManager.default.removeItem(at: jpegURL)
        }
        guard let url = Self.localGIFAvatarURL else { return }
        try? data.write(to: url)
    }

    func loadAvatarLocally() -> UIImage? {
        if let gifURL = Self.localGIFAvatarURL,
           let data = try? Data(contentsOf: gifURL) {
            return UIImage.gifImage(data: data)
        }
        guard let url = Self.localJPEGAvatarURL else { return nil }
        return (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
    }

    func logPlay(song: Song, listenSeconds: Int, bpm: Double? = nil) async {
        guard isLoggedIn else { return }
        struct Body: Encodable {
            let title: String
            let artist: String?
            let track_url: String?
            let local_song_id: String?
            let listen_seconds: Int
            let bpm: Double?
        }
        do {
            _ = try await makeRequest(
                "/user/history",
                method: "POST",
                body: Body(
                    title: song.title,
                    artist: song.artist.isEmpty ? nil : song.artist,
                    track_url: song.url?.absoluteString,
                    local_song_id: song.id,
                    listen_seconds: listenSeconds,
                    bpm: bpm
                )
            )
            appLog("logPlay: \"\(song.title)\" \(listenSeconds)s", category: "account")
        } catch {
            appWarn("logPlay: failed for \"\(song.title)\": \(error.localizedDescription)", category: "account")
        }
    }

    /// Pushes the current track/position to the bridge so other surfaces
    /// (e.g. the local Discord Rich Presence daemon) can mirror "now playing"
    /// for this account. Best-effort and silent on failure — this runs on
    /// every play/pause/track-change and periodically during playback, so it
    /// shouldn't spam logs or interrupt playback if the network is down.
    func pushPlaybackState(song: Song?, position: TimeInterval, duration: TimeInterval, isPlaying: Bool, bpm: Double? = nil) {
        guard isLoggedIn else { return }
        struct Body: Encodable {
            let song_id: String?
            let title: String?
            let artist: String?
            let track_url: String?
            let source: String?
            let position_seconds: Double
            let duration_seconds: Double
            let is_playing: Bool
            let bpm: Double?
            let artwork_url: String?
        }
        // NOT song?.url — for anything downloaded/imported that's a local
        // `file:///...` path, not a real web URL. This is specifically what
        // the Discord Rich Presence daemon's "Listen on YouTube/SoundCloud"
        // button uses (build_activity in lumisound_discord_rpc.py); Discord
        // rejects a SET_ACTIVITY payload with a non-http(s) button URL
        // outright, which broke Rich Presence entirely for the common case
        // (any currently-playing track that's actually downloaded, not
        // being streamed live) rather than just omitting the button.
        // `source` was also unconditionally nil here, so even on a build
        // that only ever streamed (never hit this bug) the button always
        // showed a generic "Open Track" instead of "Listen on YouTube".
        let sourcePrefix = song?.sourceTrackID.flatMap { id -> String? in
            guard let colon = id.firstIndex(of: ":") else { return nil }
            return String(id[id.startIndex..<colon])
        }
        let sourceWebURL: String? = {
            guard let sourceTrackID = song?.sourceTrackID, sourcePrefix == "youtube" else { return nil }
            let videoID = sourceTrackID.dropFirst("youtube:".count)
            guard !videoID.isEmpty else { return nil }
            return "https://youtube.com/watch?v=\(videoID)"
        }()
        let body = Body(
            song_id: song?.id,
            title: song?.title,
            artist: song?.artist.isEmpty == true ? nil : song?.artist,
            track_url: sourceWebURL,
            source: sourcePrefix,
            position_seconds: position,
            duration_seconds: duration,
            is_playing: isPlaying,
            bpm: bpm,
            // Deterministic from sourceTrackID alone, same accessor
            // PresenceService's heartbeat already uses for the Friends
            // "now playing" artwork — nil for local/non-YouTube sources, in
            // which case the Discord RPC daemon falls back to the
            // configured static image (build_activity in
            // lumisound_discord_rpc.py).
            artwork_url: song?.youtubeThumbnailURL?.absoluteString
        )
        playbackStatePushTask?.cancel()
        playbackStatePushTask = Task { [weak self] in
            _ = try? await self?.makeRequest("/user/playback-state", method: "PUT", body: body)
        }
    }
}
