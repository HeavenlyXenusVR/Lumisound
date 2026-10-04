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
    @ObservedObject private var aria = TVAria.shared
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

    /// "Good evening, Sam" — the one line of Home that is about the person
    /// rather than the library.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Good night" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        if let name = TVAccount.shared.user?.name, !name.isEmpty, name != "You" {
            return "\(part), \(name)"
        }
        return part
    }

    private var discoverQueue: [TVPlayable] {
        client.discoverMix.compactMap { client.playable(from: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.section) {
                VStack(alignment: .leading, spacing: 0) {
                    TVScreenTitle(title: greeting, eyebrow: "Home")
                    hero
                }
                ariaShelf
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
        .task {
            if aria.dailyPick == nil { await aria.loadDailyPick(token: token) }
        }
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

    /// Aria's pick for today. Absent entirely when she has none rather than
    /// showing an empty shelf — a section that is usually blank teaches people
    /// to skip past where it lives.
    @ViewBuilder
    private var ariaShelf: some View {
        if let pick = aria.dailyPick, pick.isPresent {
            VStack(alignment: .leading, spacing: 22) {
                TVSectionHeader(title: "From Aria", subtitle: "Picked for you today")
                    .padding(.horizontal, TVMetrics.margin)
                TVAriaDailyPickCard(pick: pick)
                    .padding(.horizontal, TVMetrics.margin)
            }
        }
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
                        TVPillLabel(title: "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            )
        } else if client.isLoadingLibrary {
            TVLoadingState(text: "Loading your library…")
                .frame(height: 400)
        } else {
            emptyHero
        }
    }

    private var emptyHero: some View {
        VStack(spacing: 26) {
            TVBrandMark(height: 70)
            Text("Welcome to Lumisound")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
            Text("Add music to your Personal Cloud Library from the iPhone app and it will appear here, ready to play.")
                .font(TVType.body)
                .foregroundStyle(TVPalette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
        }
        .frame(height: 460)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(TVPalette.brand)
                .opacity(0.18)
        }
        .padding(.horizontal, TVMetrics.margin)
        .padding(.top, 36)
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
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .tvTrackActions(client: client, token: token, track: track)
                    }
                },
                seeAll: { TVLibraryView(client: client, token: token) }
            )
        }
    }

    private func libraryCard(_ track: UserMusicTrack) -> some View {
        TVArtworkCardLabel(
            title: track.displayTitle,
            subtitle: track.artist.isEmpty ? "Unknown Artist" : track.artist,
            width: TVMetrics.shelfCard
        ) {
            TVAuthImage(url: client.userMusicArtworkURL(for: track), token: token) {
                TVArtPlaceholder(systemImage: "music.note")
            }
        }
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
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                },
                seeAll: { TVPlaylistsView(client: client, token: token) }
            )
        }
    }

    private func playlistCard(_ playlist: TVPlaylist) -> some View {
        TVArtworkCardLabel(
            title: playlist.name,
            subtitle: tvSongCount(playlist.tracks.count),
            width: TVMetrics.shelfCard
        ) {
            TVPlaylistArtwork(name: playlist.name,
                              artworkURLs: client.artworkURLs(for: playlist, token: token),
                              token: token)
        }
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
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
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
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                },
                seeAll: { TVDiscoverView(client: client, token: token) }
            )
        }
    }

    private func smartPlaylistCard(_ bucket: TVSmartPlaylistBucket) -> some View {
        TVArtworkCardLabel(
            title: bucket.name,
            subtitle: tvSongCount(bucket.tracks.count),
            width: TVMetrics.shelfCard
        ) {
            TVGeneratedArt(seed: bucket.key, systemImage: tvSmartPlaylistIcon(bucket.key),
                           title: bucket.name)
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
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .tvSearchTrackActions(client: client, token: token, track: track)
                    }
                },
                seeAll: { TVDiscoverView(client: client, token: token) }
            )
        }
    }
}
