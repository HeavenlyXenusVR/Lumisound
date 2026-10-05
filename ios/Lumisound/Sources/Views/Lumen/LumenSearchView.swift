import SwiftUI

// MARK: - Search

/// One field for the whole library — songs, artists, albums, playlists —
/// with a jump into Cloud search for anything you don't own yet. With no
/// query it becomes a browse page: recent searches, tools, and genres.
struct LumenSearchView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var account: AccountService

    @AppStorage("lumen_recent_searches") private var recentRaw: String = ""

    @State private var query = ""
    @State private var results = Results()
    @State private var cloudQuery: CloudQuery?
    @State private var showHumToSearch = false

    private struct CloudQuery: Identifiable {
        let id = UUID()
        let text: String
    }

    struct Results {
        var songs: [Song] = []
        var artists: [String] = []
        var albums: [String] = []
        var playlists: [Playlist] = []
        var isEmpty: Bool { songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty }
    }

    private var recents: [String] {
        recentRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LumenScreenHeader(eyebrow: "Find anything", title: "Search")

                LumenSearchField(text: $query, prompt: "Songs, artists, albums, playlists", onSubmit: rememberQuery)
                    .padding(.horizontal, LumenMetrics.gutter)

                if trimmedQuery.isEmpty {
                    browse
                } else {
                    resultsView
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(trimmedQuery)|\(library.allSongs.count)") { await search() }
        .sheet(item: $cloudQuery) { item in
            StreamSearchView(initialSearchText: item.text)
                .environmentObject(streaming)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(account)
        }
        .sheet(isPresented: $showHumToSearch) {
            HumToSearchView()
                .environmentObject(library)
                .environmentObject(player)
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var browse: some View {
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent")
                        .font(LumenType.title(19))
                        .foregroundStyle(LumenPalette.textPrimary)
                    Spacer()
                    Button("Clear") { recentRaw = "" }
                        .font(LumenType.caption(13))
                        .foregroundStyle(LumenPalette.accent)
                }
                FlowChips(items: recents) { item in
                    query = item
                }
            }
            .padding(.horizontal, LumenMetrics.gutter)
        }

        HStack(spacing: 12) {
            toolCard(title: "Cloud", subtitle: "Stream & download", icon: "icloud.and.arrow.down.fill",
                     colors: [LumenPalette.azure, Color(red: 0.2, green: 0.35, blue: 0.95)]) {
                cloudQuery = CloudQuery(text: "")
            }
            toolCard(title: "Hum it", subtitle: "Find by melody", icon: "waveform.and.mic",
                     colors: [LumenPalette.iris, Color(red: 0.75, green: 0.3, blue: 0.85)]) {
                showHumToSearch = true
            }
        }
        .padding(.horizontal, LumenMetrics.gutter)

        if !library.genres.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Browse Genres")
                    .font(LumenType.title(19))
                    .foregroundStyle(LumenPalette.textPrimary)
                    .padding(.horizontal, LumenMetrics.gutter)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(library.genres.prefix(16), id: \.self) { genre in
                        NavigationLink(value: LumenRoute.genre(genre)) {
                            ZStack(alignment: .bottomLeading) {
                                LumenGeneratedArt(seed: genre)
                                Text(genre)
                                    .font(LumenType.title(16))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .padding(12)
                            }
                            .frame(height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(LumenPressStyle())
                    }
                }
                .padding(.horizontal, LumenMetrics.gutter)
            }
        }
    }

    private func toolCard(title: String, subtitle: String, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(LumenType.headline(16)).foregroundStyle(.white)
                    Text(subtitle).font(LumenType.caption(12)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(LumenPressStyle())
    }

    // MARK: Results

    @ViewBuilder
    private var resultsView: some View {
        Button {
            rememberQuery()
            cloudQuery = CloudQuery(text: trimmedQuery)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.down.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LumenPalette.glow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Search the cloud for “\(trimmedQuery)”")
                        .font(LumenType.headline(14))
                        .foregroundStyle(LumenPalette.textPrimary)
                        .lineLimit(1)
                    Text("YouTube, SoundCloud and your server library")
                        .font(LumenType.caption(12))
                        .foregroundStyle(LumenPalette.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LumenPalette.textTertiary)
            }
            .lumenCard(radius: 18, padding: 12)
        }
        .buttonStyle(LumenPressStyle())
        .padding(.horizontal, LumenMetrics.gutter)

        if results.isEmpty {
            LumenEmptyState(systemImage: "magnifyingglass", title: "Not in your library",
                            message: "Nothing you own matches “\(trimmedQuery)”. Try the cloud search above.")
        }

        if !results.artists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LumenSectionHeader(title: "Artists")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(results.artists, id: \.self) { artist in
                            NavigationLink(value: LumenRoute.artist(artist)) {
                                VStack(spacing: 6) {
                                    ArtistAvatar(artist: artist, size: 84)
                                        .clipShape(Circle())
                                    Text(artist)
                                        .font(LumenType.headline(12))
                                        .foregroundStyle(LumenPalette.textPrimary)
                                        .lineLimit(1)
                                        .frame(width: 84)
                                }
                            }
                            .buttonStyle(LumenPressStyle())
                            .simultaneousGesture(TapGesture().onEnded(rememberQuery))
                        }
                    }
                    .padding(.horizontal, LumenMetrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }

        if !results.songs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                LumenSectionHeader(title: "Songs", subtitle: LumenFormat.count(results.songs.count, "match", "matches"))
                    .padding(.bottom, 6)
                ForEach(results.songs.prefix(30)) { song in
                    LumenTrackRow(song: song) {
                        rememberQuery()
                        player.play(song: song, in: results.songs)
                    }
                }
            }
        }

        if !results.albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LumenSectionHeader(title: "Albums")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(results.albums, id: \.self) { album in
                            NavigationLink(value: LumenRoute.album(album)) {
                                LumenShelfCard(title: album, subtitle: library.songs(inAlbum: album).first?.artistName, width: 130) {
                                    LumenArtwork(song: library.songs(inAlbum: album).first, size: 130, radius: 16, fallbackSeed: album)
                                }
                            }
                            .buttonStyle(LumenPressStyle())
                            .simultaneousGesture(TapGesture().onEnded(rememberQuery))
                        }
                    }
                    .padding(.horizontal, LumenMetrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }

        if !results.playlists.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                LumenSectionHeader(title: "Playlists").padding(.bottom, 6)
                ForEach(results.playlists) { playlist in
                    NavigationLink(value: LumenRoute.playlist(playlist.id)) {
                        HStack(spacing: 14) {
                            LumenCollage(songs: library.collageSongs(from: library.songs(for: playlist)), size: 50, radius: 10, seed: playlist.name)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).font(LumenType.headline(15)).foregroundStyle(LumenPalette.textPrimary)
                                Text(LumenFormat.count(playlist.songCount, "song")).font(LumenType.caption(12)).foregroundStyle(LumenPalette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(LumenPalette.textTertiary)
                        }
                        .padding(.horizontal, LumenMetrics.gutter)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(LumenPressStyle(scale: 0.98))
                }
            }
        }
    }

    // MARK: Logic

    private func search() async {
        let q = trimmedQuery
        guard !q.isEmpty else { results = Results(); return }
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        let songs = library.allSongs
        let artists = library.artists
        let albums = library.albums
        let playlists = library.playlists
        let found = await Task.detached(priority: .userInitiated) { () -> Results in
            func rank(_ text: String) -> Int? {
                if text.compare(q, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
                if text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 1 }
                if text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return 2 }
                return nil
            }
            let rankedSongs = songs.compactMap { song -> (Song, Int)? in
                let best = [rank(song.displayName), rank(song.artistName).map { $0 + 1 }, rank(song.albumName).map { $0 + 2 }]
                    .compactMap { $0 }.min()
                return best.map { (song, $0) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.displayName < $1.0.displayName }
            .map(\.0)
            let rankedArtists = artists.compactMap { a in rank(a).map { (a, $0) } }.sorted { $0.1 < $1.1 }.prefix(15).map(\.0)
            let rankedAlbums = albums.compactMap { a in rank(a).map { (a, $0) } }.sorted { $0.1 < $1.1 }.prefix(15).map(\.0)
            let matchedPlaylists = playlists.filter { rank($0.name) != nil }
            return Results(songs: rankedSongs, artists: Array(rankedArtists), albums: Array(rankedAlbums), playlists: matchedPlaylists)
        }.value
        guard !Task.isCancelled else { return }
        results = found
    }

    private func rememberQuery() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        var list = recents.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentRaw = list.prefix(10).joined(separator: "\n")
    }
}

// MARK: - Flow chips

/// Wrapping row of chips (recent searches).
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        LumenFlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                LumenChip(title: item, systemImage: "clock.arrow.circlepath") { onTap(item) }
            }
        }
    }
}

/// Minimal wrapping layout.
struct LumenFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
