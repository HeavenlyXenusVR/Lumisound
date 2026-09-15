import SwiftUI

// MARK: - TVHomeView
//
// The Home hub — the "complete teardown" of the old flat per-tab-grid shell:
// a single curated landing page (hero + horizontal shelves), Apple TV+/Music-
// app style, instead of a bare TabView opening straight onto a generic grid.
// Every shelf here is real data already fetched by the existing screens
// (Library/Playlists/Discover) — Home doesn't introduce a parallel data
// model, it just re-presents what's already there as a front page, with a
// "See All" into the existing full screen for anything that wants more than
// a shelf's worth.

struct TVHomeView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    // Cached, NOT computed properties.
    //
    // These were `client.library.sorted { ... }` and a `compactMap` off that
    // sort. A computed property has no memory, so each of the six places Home
    // reads them re-ran the whole sort — and every read of the sort key parsed
    // an ISO 8601 timestamp (see `tvParseISO8601`). SwiftUI re-evaluates `body`
    // on any `@Published` change on `client`, and the player's own position
    // publishes twice a second, so this ran continuously rather than once.
    //
    // Sorting the library is genuinely O(n log n) work that only changes when
    // the library does, which is the definition of something that belongs in
    // state updated by `.task(id:)` rather than in a getter. Same fix, and the
    // same reason, as `TVAlbumsGridView.cachedAlbums`.
    @State private var recentlyAdded: [UserMusicTrack] = []
    @State private var libraryQueue: [TVPlayable] = []

    private var heroTrack: UserMusicTrack? { recentlyAdded.first }

    private var discoverQueue: [TVPlayable] {
        client.discoverMix.compactMap { client.playable(from: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                hero
                recentlyAddedShelf
                yourPlaylistsShelf
                discoverMixShelf
                smartPlaylistsShelf
                onThisDayShelf
            }
            .padding(.bottom, 80)
        }
        .task {
            if client.library.isEmpty { await client.fetchLibrary(token: token) }
            if client.playlists.isEmpty { await client.fetchPlaylists(token: token) }
            if client.discoverMix.isEmpty { await client.fetchDiscoverMix(token: token) }
            if client.smartPlaylists.isEmpty { await client.fetchSmartPlaylists(token: token) }
            if client.onThisDay.isEmpty { await client.fetchOnThisDay(token: token) }
        }
        .task(id: client.library.count) { await rebuildRecentlyAdded() }
    }

    /// Re-sorts off the main actor. The sort is the expensive half; building
    /// playables is cheap but is done in the same hop so the two can never be
    /// momentarily out of step with each other.
    private func rebuildRecentlyAdded() async {
        let library = client.library
        let started = Date()
        let sorted = await Task.detached(priority: .userInitiated) {
            library.sorted {
                ($0.uploadedDate ?? .distantPast) > ($1.uploadedDate ?? .distantPast)
            }
        }.value
        recentlyAdded = sorted
        libraryQueue = sorted.compactMap { client.playable(from: $0, token: token) }
        TVRemoteLogger.log(
            category: "performance", event: "home_sort_completed",
            detail: ["trackCount": sorted.count,
                     "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)]
        )
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        if let track = heroTrack, let first = libraryQueue.first {
            TVHeroBanner(
                eyebrow: "Recently Added",
                title: track.displayTitle,
                subtitle: track.artist.isEmpty ? "Unknown Artist" : track.artist,
                art: {
                    TVAuthImage(url: client.userMusicArtworkURL(for: track), token: token) {
                        TVArtPlaceholder(systemImage: "music.note", iconScale: 2.4)
                    }
                },
                playButton: {
                    NavigationLink(value: TVPlayContext(queue: libraryQueue, startID: first.id)) {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.card)
                }
            )
        } else if client.isLoadingLibrary {
            VStack {
                ProgressView("Loading your library…")
            }
            .frame(height: 620)
            .frame(maxWidth: .infinity)
        } else {
            emptyHero
        }
    }

    private var emptyHero: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles.tv").font(.system(size: 80)).foregroundStyle(.secondary)
            Text("Welcome to Lumisound").font(.system(size: 40, weight: .bold))
            Text("Add music to your Personal Cloud Library from the iPhone app to see it here.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 700)
        }
        .frame(height: 620)
        .frame(maxWidth: .infinity)
    }

    // MARK: Recently Added

    @ViewBuilder
    private var recentlyAddedShelf: some View {
        // Skip the hero's own track so the shelf reads as "everything else",
        // not "the same track twice."
        let rest = Array(recentlyAdded.dropFirst())
        if !rest.isEmpty {
            TVShelfSection(
                title: "Recently Added",
                subtitle: "The newest additions to your Personal Cloud Library",
                content: {
                    ForEach(rest.prefix(16)) { track in
                        NavigationLink(value: TVPlayContext(queue: libraryQueue, startID: track.id)) {
                            libraryCard(track)
                        }
                        .buttonStyle(.card)
                        .tvTrackActions(client: client, token: token, track: track)
                    }
                },
                seeAll: { TVLibraryView(client: client, token: token) }
            )
        }
    }

    private func libraryCard(_ track: UserMusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TVAuthImage(url: client.userMusicArtworkURL(for: track), token: token) {
                TVArtPlaceholder(systemImage: "music.note")
            }
            .frame(width: 280, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(track.displayTitle)
                .font(.headline).lineLimit(2, reservesSpace: true)
            Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 280)
    }

    // MARK: Your Playlists

    @ViewBuilder
    private var yourPlaylistsShelf: some View {
        if !client.playlists.isEmpty {
            TVShelfSection(
                title: "Your Playlists",
                content: {
                    ForEach(client.playlists.prefix(16)) { playlist in
                        NavigationLink {
                            TVPlaylistDetailView(client: client, token: token, playlist: playlist)
                        } label: {
                            playlistCard(playlist)
                        }
                        .buttonStyle(.card)
                    }
                },
                seeAll: { TVPlaylistsView(client: client, token: token) }
            )
        }
    }

    private func playlistCard(_ playlist: TVPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TVArtPlaceholder(systemImage: "music.note.list", iconScale: 1.15)
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(playlist.name).font(.headline).lineLimit(2, reservesSpace: true)
            Text("\(playlist.tracks.count) \(playlist.tracks.count == 1 ? "song" : "songs")")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(width: 280)
    }

    // MARK: Discover Mix

    @ViewBuilder
    private var discoverMixShelf: some View {
        if !client.discoverMix.isEmpty {
            TVShelfSection(
                title: "Discover Mix",
                subtitle: "Suggested based on your most-played artists",
                content: {
                    ForEach(client.discoverMix.prefix(16)) { track in
                        NavigationLink(value: TVPlayContext(queue: discoverQueue, startID: track.id)) {
                            TVTrackCard(track: track)
                        }
                        .buttonStyle(.card)
                        .tvSearchTrackActions(client: client, token: token, track: track)
                    }
                },
                seeAll: { TVDiscoverView(client: client, token: token) }
            )
        }
    }

    // MARK: Smart Playlists

    @ViewBuilder
    private var smartPlaylistsShelf: some View {
        if !client.smartPlaylists.isEmpty, !client.smartPlaylists.allSatisfy({ $0.tracks.isEmpty }) {
            TVShelfSection(
                title: "Smart Playlists",
                subtitle: "Auto-generated from your cloud library's tempo",
                content: {
                    ForEach(client.smartPlaylists) { bucket in
                        NavigationLink {
                            TVSmartPlaylistDetailView(client: client, token: token, bucket: bucket)
                        } label: {
                            smartPlaylistCard(bucket)
                        }
                        .buttonStyle(.card)
                    }
                },
                seeAll: { TVDiscoverView(client: client, token: token) }
            )
        }
    }

    private func smartPlaylistCard(_ bucket: TVSmartPlaylistBucket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TVArtPlaceholder(systemImage: smartPlaylistIcon(bucket.key), iconScale: 1.15)
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(bucket.name).font(.headline)
            Text("\(bucket.tracks.count) \(bucket.tracks.count == 1 ? "song" : "songs")")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(width: 280)
    }

    private func smartPlaylistIcon(_ key: String) -> String {
        switch key {
        case "energetic": return "bolt.fill"
        case "focus": return "brain.head.profile"
        case "chill": return "cloud.fill"
        case "sleep": return "moon.zzz.fill"
        default: return "music.note.list"
        }
    }

    // MARK: On This Day

    @ViewBuilder
    private var onThisDayShelf: some View {
        if let group = client.onThisDay.first {
            let queue = group.tracks.compactMap { client.playable(from: $0) }
            TVShelfSection(
                title: group.yearsAgo == 1 ? "On This Day: 1 Year Ago" : "On This Day: \(group.yearsAgo) Years Ago",
                content: {
                    ForEach(group.tracks) { track in
                        NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                            TVTrackCard(track: track)
                        }
                        .buttonStyle(.card)
                        .tvSearchTrackActions(client: client, token: token, track: track)
                    }
                },
                seeAll: { TVDiscoverView(client: client, token: token) }
            )
        }
    }
}
