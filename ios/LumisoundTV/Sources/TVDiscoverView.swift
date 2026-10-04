import SwiftUI

// MARK: - TVDiscoverView
//
// Round 3: Discover Mix, On This Day, and server-computed Smart Playlists —
// all bridge-backed (GET /user/discover-mix, /user/on-this-day, /user/music/
// smart-playlists), unlike iOS's on-device Lua smart-playlist engine / mood
// playlist service, which read the local library scan tvOS doesn't have.
// Discover Mix and On This Day both need real play history to have anything
// to show — TVPlayerModel now reports plays via POST /user/history as it
// plays, same as this screen's data ultimately depends on.

struct TVDiscoverView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    private var discoverQueue: [TVPlayable] {
        client.discoverMix.compactMap { client.playable(from: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.section) {
                TVScreenTitle(title: "Discover", eyebrow: "Made for you")
                subscriptionFeedSection
                discoverMixSection
                onThisDaySection
                smartPlaylistsSection
                nothingYetHint
            }
            .padding(.bottom, 80)
        }
        .task {
            if client.discoverMix.isEmpty { await client.fetchDiscoverMix(token: token) }
            if client.onThisDay.isEmpty { await client.fetchOnThisDay(token: token) }
            if client.smartPlaylists.isEmpty { await client.fetchSmartPlaylists(token: token) }
            if client.subscriptionFeed.isEmpty { await client.fetchSubscriptionFeed(token: token) }
        }
    }

    /// Shown only when EVERY shelf is empty. Each section used to carry its
    /// own apology row, so a new account saw three separate "nothing here yet"
    /// bands stacked down the screen and had to scroll past all of them. One
    /// explanation, once, and only when there is genuinely nothing to browse.
    @ViewBuilder
    private var nothingYetHint: some View {
        let stillLoading = client.isLoadingDiscoverMix || client.isLoadingOnThisDay
            || client.isLoadingSubscriptionFeed
        let everythingEmpty = client.discoverMix.isEmpty && client.onThisDay.isEmpty
            && client.smartPlaylists.isEmpty && client.subscriptionFeed.isEmpty
        if everythingEmpty && !stillLoading {
            TVEmptyState(
                systemImage: "sparkles",
                title: "Discover fills in as you listen",
                message: "Play a few tracks and suggestions, anniversaries and tempo-based playlists will appear here."
            )
        }
    }

    // MARK: Subscriptions feed (new uploads from channels you follow —
    // read-only on tvOS; managing subscriptions/auto-download stays iOS-only)

    @ViewBuilder
    private var subscriptionFeedSection: some View {
        if client.isLoadingSubscriptionFeed || !client.subscriptionFeed.isEmpty {
            TVShelfSection(title: "New From Your Subscriptions", subtitle: "Recent uploads from channels you follow") {
                if client.isLoadingSubscriptionFeed {
                    TVLoadingBars(height: 40).frame(height: 190)
                } else {
                    let queue = client.subscriptionFeed.compactMap { $0.track }.compactMap { client.playable(from: $0) }
                    ForEach(client.subscriptionFeed) { item in
                        if let track = item.track {
                            NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                                TVTrackCard(track: track)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .tvSearchTrackActions(client: client, token: token, track: track)
                        }
                    }
                }
            }
        }
    }

    // MARK: Discover Mix

    @ViewBuilder
    private var discoverMixSection: some View {
        // Collapsed entirely when there's nothing to show. An empty shelf here
        // still rendered a heading, a subtitle and a full-width apology — a
        // whole band of screen spent saying "nothing" and pushing real content
        // below the fold. See `nothingYetHint` for the one place that explains
        // an empty Discover, shown once rather than once per section.
        if client.isLoadingDiscoverMix || !client.discoverMix.isEmpty {
        TVShelfSection(title: "Discover Mix", subtitle: "Based on your most-played artists") {
            if client.isLoadingDiscoverMix {
                TVLoadingBars(height: 40).frame(height: 190)
            } else {
                ForEach(client.discoverMix) { track in
                    NavigationLink(value: TVPlayContext(queue: discoverQueue, startID: track.id)) {
                        TVTrackCard(track: track)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .tvSearchTrackActions(client: client, token: token, track: track)
                }
            }
        }
        }
    }

    // MARK: On This Day

    private var onThisDaySection: some View {
        VStack(alignment: .leading, spacing: 40) {
            if client.isLoadingOnThisDay {
                TVSectionHeader(title: "On This Day").padding(.horizontal, TVMetrics.margin)
                TVLoadingBars(height: 40).padding(.horizontal, TVMetrics.margin)
            } else if client.onThisDay.isEmpty {
                // Nothing at all: this date genuinely has no history most days,
                // so a permanent empty band here would be the normal case.
                EmptyView()
            } else {
                ForEach(client.onThisDay) { group in
                    let queue = group.tracks.compactMap { client.playable(from: $0) }
                    TVShelfSection(title: group.yearsAgo == 1 ? "On This Day: 1 Year Ago" : "On This Day: \(group.yearsAgo) Years Ago") {
                        ForEach(group.tracks) { track in
                            NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                                TVTrackCard(track: track)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .tvSearchTrackActions(client: client, token: token, track: track)
                        }
                    }
                }
            }
        }
    }

    // MARK: Smart playlists

    @ViewBuilder
    private var smartPlaylistsSection: some View {
        // Collapsed entirely when every bucket is empty — a heading over
        // nothing is a band of screen spent saying "nothing".
        if client.isLoadingSmartPlaylists
            || !client.smartPlaylists.allSatisfy({ $0.tracks.isEmpty }) {
        TVShelfSection(title: "Smart Playlists", subtitle: "Auto-generated from your cloud library's tempo") {
            if client.isLoadingSmartPlaylists {
                TVLoadingBars(height: 40).frame(height: 190)
            } else {
                ForEach(client.smartPlaylists) { bucket in
                    NavigationLink {
                        TVSmartPlaylistDetailView(client: client, token: token, bucket: bucket)
                    } label: {
                        smartPlaylistCard(bucket)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        }
    }

    private func smartPlaylistCard(_ bucket: TVSmartPlaylistBucket) -> some View {
        TVArtworkCardLabel(title: bucket.name, subtitle: tvSongCount(bucket.tracks.count),
                           width: TVMetrics.shelfCard) {
            TVGeneratedArt(seed: bucket.key, systemImage: tvSmartPlaylistIcon(bucket.key),
                           title: bucket.name)
        }
    }
}

// MARK: - Smart playlist detail

struct TVSmartPlaylistDetailView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let bucket: TVSmartPlaylistBucket

    /// Resolved against the loaded library by filename — see
    /// `TVBridgeClient.resolvedTrack(for:)`. An entry that doesn't resolve
    /// (library not loaded yet, or a genuine mismatch) is dropped rather
    /// than shown unplayable.
    private var resolvedTracks: [UserMusicTrack] {
        bucket.tracks.compactMap { client.resolvedTrack(for: $0) }
    }
    private var queue: [TVPlayable] {
        resolvedTracks.compactMap { client.playable(from: $0, token: token) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                TVDetailHeader(
                    eyebrow: "Smart Playlist",
                    title: bucket.name,
                    subtitle: "Built from your cloud library's tempo",
                    meta: tvCollectionMeta(resolvedTracks)
                ) {
                    TVGeneratedArt(seed: bucket.key, systemImage: tvSmartPlaylistIcon(bucket.key))
                } actions: {
                    if let first = queue.first {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            TVPillLabel(title: "Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }

                if client.isLoadingLibrary {
                    TVLoadingState(text: "Matching against your library…")
                } else if resolvedTracks.isEmpty {
                    TVEmptyState(systemImage: "waveform.slash",
                                 title: "Nothing matched",
                                 message: "None of this playlist's songs were found in your cloud library.")
                } else {
                    TVTrackList {
                        ForEach(resolvedTracks) { track in
                            NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                                TVTrackRow(
                                    artworkURL: client.userMusicArtworkURL(for: track),
                                    token: token,
                                    title: track.displayTitle,
                                    artist: track.artist,
                                    detail: track.duration.tvDurationText,
                                    isFavorite: client.isFavorite(track.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .tvTrackActions(client: client, token: token, track: track)
                        }
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .tvAmbientBackground()
        .task {
            if client.library.isEmpty { await client.fetchLibrary(token: token) }
        }
    }
}
