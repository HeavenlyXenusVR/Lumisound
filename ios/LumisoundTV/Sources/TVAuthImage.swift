import SwiftUI

// MARK: - TVAuthImage
//
// AsyncImage can't attach an Authorization header, which the per-user artwork
// endpoint requires. This loads the image via URLSession with an optional Bearer
// token and falls back to a placeholder.
//
// Two things this fixes over a naive "set image = nil, then load" version:
//   1. It used to clear the displayed image the INSTANT `url` changed (the
//      first line of `load()`), before the new one had even started
//      downloading — every track change flashed to the gray placeholder for
//      a beat, then popped to the new artwork once it arrived. Now the old
//      image stays on screen and cross-dissolves into the new one instead.
//   2. A failed fetch (a dropped connection, a transient CDN hiccup) used to
//      mean permanently blank artwork for that url with no second attempt —
//      this is what a "the thumbnail never shows up" report traces back to
//      more often than a genuinely missing/dead URL. One retry after a short
//      delay covers the transient case without hammering a URL that's
//      actually gone.
/// Artwork loads go through their own session, not `URLSession.shared`.
///
/// Telemetry showed 300 artwork failures in a day with status -1 — no HTTP
/// response at all. Not missing files: the grids request dozens of covers at
/// once (more since the column count became configurable), and the default
/// session allows only a handful of connections per host, so the rest queue and
/// time out. The failures scale with how fast you scroll, which is exactly the
/// shape of connection starvation rather than of anything being wrong on the
/// server.
///
/// A larger connection pool lets a screenful actually load, and a real cache
/// means scrolling back to a row costs nothing — the previous behaviour refetched
/// every cover every time it came back on screen, which was most of the load
/// causing the starvation in the first place.
private let tvArtworkSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 12
    config.requestCachePolicy = .returnCacheDataElseLoad
    config.timeoutIntervalForRequest = 25
    config.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024,
                               diskCapacity: 512 * 1024 * 1024,
                               diskPath: "tv-artwork")
    return URLSession(configuration: config)
}()

struct TVAuthImage<Placeholder: View>: View {
    let url: URL?
    let token: String?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var currentImage: UIImage?
    @State private var incomingImage: UIImage?
    @State private var showIncoming = false

    var body: some View {
        ZStack {
            if currentImage == nil && incomingImage == nil {
                placeholder()
            }
            if let currentImage {
                Image(uiImage: currentImage)
                    .resizable().scaledToFill()
                    .opacity(showIncoming ? 0 : 1)
            }
            if let incomingImage {
                Image(uiImage: incomingImage)
                    .resizable().scaledToFill()
                    .opacity(showIncoming ? 1 : 0)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            currentImage = nil
            incomingImage = nil
            showIncoming = false
            return
        }

        var result = await fetch(url)
        if result.image == nil {
            result = await fetch(url, afterDelayNanoseconds: 900_000_000)
        }
        let lastStatus = result.status
        let ui = result.image
        // A cancelled load is not an error. `.task(id:)` cancels this the moment
        // the row scrolls off, which on a long list happens constantly — logging
        // those as failures buried the real ones and made artwork look far more
        // broken than it was.
        if Task.isCancelled { return }

        guard let ui else {
            // Both attempts failed — leave whatever was already on screen
            // (e.g. the previous track's art, or the placeholder) rather
            // than clearing it; a blank frame is a worse failure mode than a
            // stale-for-a-moment one.
            //
            // Reported once per load (not per attempt) with the status code,
            // because silently keeping the old frame is exactly why "locked
            // tracks have no artwork" produced no evidence anywhere: the UI
            // degrades gracefully and the failure left no trace at all. 404
            // here means the server has no stored thumbnail for a locked
            // track — it cannot extract one from locked bytes, so a
            // pre-uploaded thumbnail is its only source.
            // 404 is a normal state, not a fault: the server has no stored
            // thumbnail for that track and cannot extract one from locked bytes.
            // Logged at info so it stays countable without sitting in the error
            // feed next to genuine failures.
            TVRemoteLogger.log(
                category: "artwork",
                event: lastStatus == 404 ? "artwork_absent" : "artwork_load_failed",
                level: lastStatus == 404 ? "info" : "error",
                message: "HTTP \(lastStatus)",
                detail: ["status": lastStatus, "url": url.path,
                         "isUserMusic": url.path.contains("/user/music/artwork"),
                         "hadToken": token != nil],
                authToken: token
            )
            return
        }

        incomingImage = ui
        showIncoming = false
        withAnimation(.easeInOut(duration: 0.35)) {
            showIncoming = true
        }
        try? await Task.sleep(nanoseconds: 380_000_000)
        guard !Task.isCancelled else { return }
        currentImage = ui
        incomingImage = nil
        showIncoming = false
    }

    /// Returns the decoded image and the HTTP status that produced it.
    /// Status is RETURNED rather than stored: this is a SwiftUI `View` struct,
    /// so a stored mutable property both breaks the memberwise initialiser
    /// every call site uses and can't be assigned from a non-mutating context.
    /// -1 = no HTTP response at all (offline/cancelled); -2 = bytes returned
    /// that weren't a decodable image.
    private func fetch(_ url: URL, afterDelayNanoseconds delay: UInt64? = nil) async -> (image: UIImage?, status: Int) {
        if let delay {
            try? await Task.sleep(nanoseconds: delay)
            // -1: cancelled before any request was made, same as "no HTTP response".
            guard !Task.isCancelled else { return (nil, -1) }
        }
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await tvArtworkSession.data(for: req) else {
            return (nil, -1)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            return (nil, status)
        }
        guard let ui = UIImage(data: data) else {
            return (nil, -2)
        }
        return (ui, status)
    }
}
