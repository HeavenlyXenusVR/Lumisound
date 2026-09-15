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
                // Three columns: navigation | content | what's playing.
                //
                // This replaces a top nav bar over a full-width content area with
                // a mini-player strip inset across the bottom. Side by side, a
                // left/right move changes region and an up/down move stays inside
                // one, so navigation is no longer in the path of scrolling a list
                // and the player is no longer in the path of leaving it.
                //
                // The player column is composed with a plain `if`. v1.7.0 pinned
                // the player as a `safeAreaInset` that rendered an empty view when
                // nothing was playing, and wrapped it in a focus section — a
                // zero-size focus section inside a safe-area inset, in exactly the
                // state the app launches in, which made it relaunch in a loop.
                // Here, nothing playing means no view at all: nothing to size,
                // nothing to focus, no empty branch to get wrong.
                HStack(spacing: 0) {
                    TVSideRail(
                        selection: $selection,
                        accountName: account.user?.name ?? "Account",
                        accountBadge: client.notifications.filter(\.isUnread).count,
                        user: account.user,
                        baseURL: client.baseURL
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
                    .frame(maxWidth: .infinity)
                    .focusSection()

                    // The player column is HIDDEN on Search.
                    //
                    // tvOS's search surface brings the system keyboard, which it
                    // lays out across the full width of the window regardless of
                    // what else is on screen — so with the card present the
                    // keyboard drew straight over it and over the rail, which is
                    // the overlap in the 1.13.2 screenshot. Nothing in the app
                    // can reposition a system keyboard, so the fix is to give the
                    // screen the width it is going to take anyway.
                    //
                    // Hidden for the full player too: that screen is pushed over
                    // this shell and already shows everything the card does.
                    if player.current != nil,
                       !player.isShowingFullPlayer,
                       selection != .search {
                        TVNowPlayingPanel(model: player, client: client, token: token)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeOut(duration: 0.3), value: player.current == nil)
                .animation(.easeOut(duration: 0.25), value: selection == .search)
                .background(TVAmbientBackground())
                .navigationDestination(for: TVPlayContext.self) { ctx in
                    TVPlayerView(context: ctx, client: client, token: token)
                }
            }
            // Fetched here (not just inside TVAccountView.task, as before) so
            // the nav bar's unread badge is accurate even before Account is
            // ever visited this session.
            .task {
                // Runs for the life of the session — see TVAdvancedTelemetry.
                TVAdvancedTelemetry.HitchMonitor.shared.start()
                TVAdvancedTelemetry.noteScreen(selection.rawValue)
                if client.notifications.isEmpty { await client.fetchNotifications(token: token) }
            }
            .onChange(of: selection) { newValue in
                TVAdvancedTelemetry.noteScreen(newValue.rawValue)
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

    private var columns: [GridItem] { TVGridLayout.columns() }
    private var queue: [TVPlayable] { client.results.compactMap { client.playable(from: $0) } }

    var body: some View {
        // UISearchController-backed so the system tvOS keyboard (and its
        // dictation microphone) is available — SwiftUI's `.searchable` has no
        // supported way to offer voice input. See TVDictationSearch.
        TVDictationSearch(text: $query, placeholder: "Search YouTube", onChange: runSearch) {
            resultsBody
        }
        .ignoresSafeArea()
    }

    private var resultsBody: some View {
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
                .padding(TVMetrics.margin)
            }
        }
    }

    /// Debounced search-as-you-type. tvOS search keyboards don't reliably fire
    /// a submit action, so the query runs as the text changes — including text
    /// arriving from dictation, which produces no submit event at all.
    private func runSearch(_ value: String) {
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard query == value else { return }  // user kept typing/speaking
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                client.results = []
                client.searchError = nil
            } else {
                await client.search(value)
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
            .frame(maxWidth: .infinity)
                .aspectRatio(16.0/9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(track.title).font(.headline).lineLimit(2, reservesSpace: true)
            Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
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
                    VStack(spacing: TVMetrics.row) {
                        accountLink("Listening Stats", systemImage: "chart.bar.fill") {
                            TVStatsView(client: client, token: token)
                        }
                        accountLink("Notifications", systemImage: "bell.fill", badge: unreadNotificationCount) {
                            TVNotificationsView(client: client, token: token)
                        }
                        accountLink("Active Sessions", systemImage: "list.bullet.rectangle") {
                            TVSessionsView(client: client, account: account, token: token)
                        }
                        accountLink("Settings", systemImage: "gearshape.fill") {
                            TVSettingsView()
                        }
                    }

                    if !client.friendsListening.isEmpty {
                        TVSectionHeader(title: "Friends Listening")
                            .padding(.top, 10)
                        TVFriendsListeningCard(friendsListening: client.friendsListening)
                    }

                    TVSectionHeader(title: "Listening Activity")
                        .padding(.top, 10)
                    TVSocialActivityFeed(activity: client.socialActivity)
                }
                // A BOUNDED width, not `maxWidth: .infinity`.
                //
                // Each row's label is an HStack containing a bare `Spacer()`,
                // which grows to whatever width it is offered. Offered infinity
                // by the column above it, inside a vertical ScrollView that does
                // not pin its content's width, the rows grew far past the screen
                // — visibly running off the right edge with no end to them.
                //
                // That is also why none of them could be reached: the tvOS focus
                // engine does not move focus onto a view lying outside the
                // visible bounds, and `.buttonStyle(.card)` scaled the focused
                // row up, pushing it further out still. The rows were rendered,
                // off-screen, and unfocusable.
                .frame(maxWidth: 760, alignment: .leading)
                // Makes the column a focus region in its own right, so moving
                // right out of the profile card has somewhere defined to land.
                // The profile column has had this since Sign Out became
                // unreachable for the same class of reason.
                .focusSection()

                Spacer(minLength: 0)
            }
            .padding(TVMetrics.margin)
        }
        .task {
            if client.notifications.isEmpty { await client.fetchNotifications(token: token) }
            await client.fetchFriendsListening(token: token)
            await client.fetchSocialActivity(token: token)
        }
    }

    private var profileCard: some View {
        VStack(spacing: 18) {
            TVAvatarView(user: account.user, baseURL: client.baseURL, diameter: 150)
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
            TVAccountRowLabel(title: title, systemImage: systemImage, badge: badge)
        }
        // `.plain` + the port's own focus treatment, matching every other row in
        // the app. `.card` applies the system lift sized for square artwork,
        // which on a full-width row reads as the screen jumping — and brought
        // the system focus halo with it, the white slab removed elsewhere.
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// One row in the Account list. Bounded by its column rather than greedy: the
/// trailing spacer pushes the badge to the row's own right edge, and the row is
/// only ever as wide as the column allows.
private struct TVAccountRowLabel: View {
    let title: String
    let systemImage: String
    var badge: Int = 0

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isFocused ? TVPalette.neon : .white.opacity(0.55))
                .frame(width: 38)

            Text(title)
                .font(.system(size: 25, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 12)

            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 17, weight: .bold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(TVPalette.neonAlt, in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(isFocused ? 0.8 : 0.3))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .tvNeonCard(isFocused: isFocused)
    }
}
