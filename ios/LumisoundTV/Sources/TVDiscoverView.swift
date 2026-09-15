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
            VStack(alignment: .leading, spacing: 50) {
                subscriptionFeedSection
                discoverMixSection
                onThisDaySection
                smartPlaylistsSection
                nothingYetHint
            }
            .padding(.vertical, 50)
        }
        .tvAmbientBackground()
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
            VStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("Discover fills in as you listen")
                    .font(.system(size: 30, weight: .semibold))
                Text("Play a few tracks and suggestions, anniversaries and tempo-based playlists will appear here.")
                    .font(.system(size: 21))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    // MARK: Subscriptions feed (new uploads from channels you follow —
    // read-only on tvOS; managing subscriptions/auto-download stays iOS-only)

    @ViewBuilder
    private var subscriptionFeedSection: some View {
        if client.isLoadingSubscriptionFeed || !client.subscriptionFeed.isEmpty {
            TVShelfSection(title: "New From Your Subscriptions", subtitle: "Recent uploads from channels you follow") {
                if client.isLoadingSubscriptionFeed {
                    ProgressView().padding(.horizontal, 60)
                } else {
                    let queue = client.subscriptionFeed.compactMap { $0.track }.compactMap { client.playable(from: $0) }
                    ForEach(client.subscriptionFeed) { item in
                        if let track = item.track {
                            NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                                TVTrackCard(track: track)
                            }
                            .buttonStyle(.card)
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
                ProgressView().padding(.horizontal, 60)
            } else {
                ForEach(client.discoverMix) { track in
                    NavigationLink(value: TVPlayContext(queue: discoverQueue, startID: track.id)) {
                        TVTrackCard(track: track)
                    }
                    .buttonStyle(.card)
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
                ProgressView().padding(.horizontal, TVMetrics.margin)
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
                            .buttonStyle(.card)
                            .tvSearchTrackActions(client: client, token: token, track: track)
                        }
                    }
                }
            }
        }
    }

    // MARK: Smart playlists

    private var smartPlaylistsSection: some View {
        TVShelfSection(title: "Smart Playlists", subtitle: "Auto-generated from your cloud library's tempo") {
            if client.isLoadingSmartPlaylists {
                ProgressView().padding(.horizontal, 60)
            } else if client.smartPlaylists.allSatisfy({ $0.tracks.isEmpty }) {
                EmptyView()
            } else {
                ForEach(client.smartPlaylists) { bucket in
                    NavigationLink {
                        TVSmartPlaylistDetailView(client: client, token: token, bucket: bucket)
                    } label: {
                        smartPlaylistCard(bucket)
                    }
                    .buttonStyle(.card)
                }
            }
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

    // MARK: Shared layout helpers

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.title3).foregroundStyle(.secondary)
            .padding(.horizontal, TVMetrics.margin)
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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(bucket.name).font(.system(size: 40, weight: .bold))
                    Text("\(resolvedTracks.count) \(resolvedTracks.count == 1 ? "song" : "songs")")
                        .font(.title3).foregroundStyle(.secondary)
                    if let first = queue.first {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.card)
                        .padding(.top, 10)
                    }
                }

                if client.isLoadingLibrary {
                    ProgressView().padding(.top, 20)
                } else if resolvedTracks.isEmpty {
                    Text("No matching songs found in your library.")
                        .font(.title3).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(resolvedTracks) { track in
                            NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                                HStack(spacing: 24) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.displayTitle).font(.title3)
                                        Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(track.durationText).font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 20)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.card)
                            .tvTrackActions(client: client, token: token, track: track)
                        }
                    }
                }
            }
            .padding(TVMetrics.margin)
        }
        .tvAmbientBackground()
        .task {
            if client.library.isEmpty { await client.fetchLibrary(token: token) }
        }
    }
}
