import SwiftUI

// MARK: - Root

struct TVContentView: View {
    @StateObject private var account = TVAccount.shared
    @StateObject private var client = TVBridgeClient.shared
    // Adopted here (not constructed) for the same reason `client`/`account`
    // are — see TVPlayerModel.shared's doc comment. Not otherwise used
    // directly in this view; holding the reference here just keeps it
    // consistent with the rest of this file's root-level singleton pattern.
    @StateObject private var player = TVPlayerModel.shared
    @State private var selection: TVDestination = .home

    var body: some View {
        if account.isLoggedIn, let token = account.token {
            NavigationStack {
                VStack(spacing: 0) {
                    TVTopNavBar(
                        selection: $selection,
                        accountName: account.user?.name ?? "Account",
                        accountBadge: client.notifications.filter(\.isUnread).count
                    )
                    ZStack {
                        switch selection {
                        case .home:
                            TVHomeView(client: client, token: token)
                        case .library:
                            TVLibraryView(client: client, token: token)
                        case .playlists:
                            TVPlaylistsView(client: client, token: token)
                        case .discover:
                            TVDiscoverView(client: client, token: token)
                        case .search:
                            TVSearchView(client: client, token: token)
                        case .account:
                            TVAccountView(client: client, account: account, token: token)
                        }
                    }
                }
                // Pinned under the whole shell so "what's playing" and the way
                // back to it are reachable from every tab — see
                // TVMiniPlayerBar. `.focusSection()` makes the bar a
                // first-class directional-focus target rather than something
                // the engine can skip past on the way between rows.
                .safeAreaInset(edge: .bottom) {
                    TVMiniPlayerBar(model: player, client: client, token: token)
                        .focusSection()
                }
                .animation(.easeOut(duration: 0.25), value: player.current?.id)
                .navigationDestination(for: TVPlayContext.self) { ctx in
                    TVPlayerView(context: ctx, client: client, token: token)
                }
            }
            // Fetched here (not just inside TVAccountView.task, as before) so
            // the nav bar's unread badge is accurate even before Account is
            // ever visited this session.
            .task {
                if client.notifications.isEmpty { await client.fetchNotifications(token: token) }
            }
        } else {
            TVLoginView(account: account)
        }
    }
}

// MARK: - Search tab

struct TVSearchView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 48)]
    private var queue: [TVPlayable] { client.results.compactMap { client.playable(from: $0) } }

    var body: some View {
        ScrollView {
            if client.isSearching {
                ProgressView("Searching… this can take a moment")
                    .padding(.top, 100)
            } else if let err = client.searchError {
                Text(err).foregroundStyle(.secondary).padding(.top, 80)
            } else if client.results.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(client.results) { track in
                        NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                            TVTrackCard(track: track)
                        }
                        .buttonStyle(.card)
                        .tvSearchTrackActions(client: client, token: token, track: track)
                    }
                }
                .padding(60)
            }
        }
        .tvAmbientBackground()
        .searchable(text: $query, prompt: "Search YouTube")
        .onSubmit(of: .search) { Task { await client.search(query) } }
        // tvOS search keyboards don't reliably fire `.onSubmit(of: .search)`, so
        // also search as you type (debounced) — otherwise typing appears to do
        // nothing.
        .onChange(of: query) { newValue in
            let v = newValue
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard query == v else { return }  // user kept typing
                if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    client.results = []
                    client.searchError = nil
                } else {
                    await client.search(v)
                }
            }
        }
    }

    /// Instead of a bare "search to play" placeholder, an empty query
    /// surfaces something real to browse straight away — the same Discover
    /// Mix data the Discover tab shows, framed as search suggestions.
    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 40) {
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass").font(.system(size: 70)).foregroundStyle(.secondary)
                Text("Search YouTube to play on your Apple TV")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 100)
            .padding(.bottom, 20)

            if !client.discoverMix.isEmpty {
                let suggestQueue = client.discoverMix.compactMap { client.playable(from: $0) }
                TVShelfSection(title: "Try One Of These", subtitle: "Based on your most-played artists") {
                    ForEach(client.discoverMix) { track in
                        NavigationLink(value: TVPlayContext(queue: suggestQueue, startID: track.id)) {
                            TVTrackCard(track: track)
                        }
                        .buttonStyle(.card)
                        .tvSearchTrackActions(client: client, token: token, track: track)
                    }
                }
            }
        }
        .task {
            if client.discoverMix.isEmpty { await client.fetchDiscoverMix(token: token) }
        }
    }
}

struct TVTrackCard: View {
    let track: TVTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TVAuthImage(url: URL(string: track.thumbnailURL), token: nil) {
                TVArtPlaceholder(systemImage: "music.note")
            }
            .frame(width: 280, height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(track.title).font(.headline).lineLimit(2, reservesSpace: true)
            Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 280)
    }
}

// MARK: - Account tab

struct TVAccountView: View {
    @ObservedObject var client: TVBridgeClient
    @ObservedObject var account: TVAccount
    let token: String

    private var unreadNotificationCount: Int {
        client.notifications.filter(\.isUnread).count
    }

    var body: some View {
        ScrollView {
            // Two-pane layout — a fixed profile card on the left, settings/
            // links and the friends-listening card filling the rest — instead
            // of everything stacked single-file down the middle of the screen.
            HStack(alignment: .top, spacing: 60) {
                profileCard
                    .frame(width: 420)
                    // `.focusSection()` makes this column a first-class target
                    // for directional focus. Sign Out is the ONLY focusable
                    // control in it, sits below a Spacer, and is much shorter
                    // than the tall right-hand column — the combination the
                    // tvOS focus engine is most likely to skip past when
                    // moving left, which leaves the button visible but
                    // unreachable. That matters more than usual here because
                    // Sign Out is the escape hatch from a bad restored
                    // session, so being unable to reach it means being unable
                    // to sign into the right account at all.
                    .focusSection()

                VStack(alignment: .leading, spacing: 30) {
                    TVSectionHeader(title: "Account")
                    VStack(spacing: 16) {
                        accountLink("Listening Stats", systemImage: "chart.bar.fill") {
                            TVStatsView(client: client, token: token)
                        }
                        accountLink("Notifications", systemImage: "bell.fill", badge: unreadNotificationCount) {
                            TVNotificationsView(client: client, token: token)
                        }
                        accountLink("Active Sessions", systemImage: "list.bullet.rectangle") {
                            TVSessionsView(client: client, account: account, token: token)
                        }
                    }

                    if !client.friendsListening.isEmpty {
                        TVSectionHeader(title: "Friends Listening")
                            .padding(.top, 10)
                        TVFriendsListeningCard(friendsListening: client.friendsListening)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(70)
        }
        .tvAmbientBackground()
        .task {
            if client.notifications.isEmpty { await client.fetchNotifications(token: token) }
            await client.fetchFriendsListening(token: token)
        }
    }

    private var profileCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 100))
                .foregroundStyle(.tint)
                .shadow(color: Color.accentColor.opacity(0.6), radius: 24)
            Text(account.user?.name ?? "Signed in")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Spacer(minLength: 20)

            Button("Sign Out", role: .destructive) { account.logout() }
        }
        .padding(30)
        .frame(minHeight: 360)
        .tvGlassPanel()
    }

    @ViewBuilder
    private func accountLink<Destination: View>(
        _ title: String, systemImage: String, badge: Int = 0, @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                }
            }
        }
        .buttonStyle(.card)
    }
}
