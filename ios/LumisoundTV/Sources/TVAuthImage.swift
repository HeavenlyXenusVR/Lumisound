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

        var ui = await fetch(url)
        if ui == nil {
            ui = await fetch(url, afterDelayNanoseconds: 900_000_000)
        }
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
            TVRemoteLogger.logError(
                category: "artwork", event: "artwork_load_failed",
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

    /// Status of the most recent `fetch` — surfaced so `load` can report WHY
    /// artwork is missing rather than just that it is. -1 means the request
    /// never produced an HTTP response (offline/cancelled); -2 means it
    /// returned bytes that weren't a decodable image.
    private var lastStatus: Int = -1

    private func fetch(_ url: URL, afterDelayNanoseconds delay: UInt64? = nil) async -> UIImage? {
        if let delay {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return nil }
        }
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            lastStatus = -1
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            lastStatus = status
            return nil
        }
        guard let ui = UIImage(data: data) else {
            lastStatus = -2
            return nil
        }
        lastStatus = status
        return ui
    }
}
