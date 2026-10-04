import SwiftUI

// MARK: - Collection artwork
//
// Playlists, smart playlists and genres have no artwork of their own on the
// bridge, so every one of them used to render as the same glyph-on-gradient
// tile. These give each collection a face:
//
//   - a playlist shows a 2×2 mosaic of the covers inside it (the convention
//     every music app uses), falling back to one cover, then to generated art
//     carrying the playlist's name;
//   - a smart playlist or genre gets generated art seeded from its name, with
//     the glyph that says what kind of mix it is.

extension TVBridgeClient {
    /// Up to `limit` distinct covers from the playable tracks of a playlist, in
    /// playlist order.
    func artworkURLs(for playlist: TVPlaylist, token: String, limit: Int = 4) -> [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []
        for track in playlist.tracks {
            guard let url = playable(from: track, token: token)?.artworkURL,
                  seen.insert(url).inserted else { continue }
            urls.append(url)
            if urls.count == limit { break }
        }
        return urls
    }
}

struct TVPlaylistArtwork: View {
    let name: String
    let artworkURLs: [URL]
    let token: String
    /// Whether to print the name on generated art — on for cards, off where
    /// the name is already printed large right beside it (detail headers).
    var showsTitle: Bool = true

    var body: some View {
        if artworkURLs.count >= 4 {
            GeometryReader { geo in
                let half = geo.size.width / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(artworkURLs[0], side: half)
                        tile(artworkURLs[1], side: half)
                    }
                    HStack(spacing: 0) {
                        tile(artworkURLs[2], side: half)
                        tile(artworkURLs[3], side: half)
                    }
                }
            }
        } else if let first = artworkURLs.first {
            TVAuthImage(url: first, token: token) { generated }
        } else {
            generated
        }
    }

    private var generated: some View {
        TVGeneratedArt(seed: name, systemImage: "music.note.list", title: showsTitle ? name : nil)
    }

    private func tile(_ url: URL, side: CGFloat) -> some View {
        TVAuthImage(url: url, token: token) {
            TVArtPlaceholder(systemImage: "music.note", iconScale: 0.6)
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

/// Glyph for a server-computed smart playlist, by its bucket key.
func tvSmartPlaylistIcon(_ key: String) -> String {
    switch key {
    case "energetic": return "bolt.fill"
    case "focus": return "brain.head.profile"
    case "chill": return "cloud.fill"
    case "sleep": return "moon.zzz.fill"
    default: return "music.note.list"
    }
}
