import SwiftUI

// MARK: - SharedPlaylistsView
//
// Playlists other users have shared with this account as a collaborator
// (editor/viewer) — GET /user/playlists/shared-with-me. Tapping one fetches
// its tracks (GET /user/playlists/{id}) and lets the user play them or save
// a local copy.

struct SharedPlaylistsView: View {
    @EnvironmentObject private var account: AccountService

    @State private var playlists: [SharedWithMePlaylist] = []
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading && playlists.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if playlists.isEmpty {
                EmptyStateView(
                    icon: "person.2.fill",
                    title: "Nothing shared yet",
                    message: "Playlists other users add you to as a collaborator will show up here."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(playlists, id: \.id) { playlist in
                    NavigationLink {
                        SharedPlaylistDetailView(summary: playlist)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playlist.name)
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("by \(playlist.ownerUsername) · \(playlist.role.capitalized)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(AppTheme.surface.opacity(0.5))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Shared with Me")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        playlists = await account.fetchSharedPlaylists()
        isLoading = false
    }
}

// MARK: - SharedPlaylistDetailView

private struct SharedPlaylistDetailView: View {
    let summary: SharedWithMePlaylist

    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var detail: SharedPlaylistDetail?
    @State private var isLoading = false
    @State private var didSaveCopy = false

    private var songs: [Song] {
        guard let detail else { return [] }
        // uniquingKeysWith:, not uniqueKeysWithValues: — the latter traps
        // (crashes) on any duplicate id, which `library.allSongs` isn't
        // guaranteed to be free of (see the matching fix/comment in
        // LibraryManager+SongRemoval.swift's rebuildAllSongs).
        // The library's own id index, instead of rebuilding a dictionary of
        // the whole library on every render.
        let songsByID = library.songsByID
        return detail.tracks.compactMap { track -> Song? in
            if let localID = track.localSongId, let song = songsByID[localID] {
                return song
            }
            if let urlString = track.trackUrl, let url = URL(string: urlString) {
                return Song(
                    title: track.title,
                    artist: track.artist ?? "",
                    album: track.album ?? "",
                    duration: TimeInterval(track.durationSeconds ?? 0),
                    url: url
                )
            }
            return nil
        }
    }

    var body: some View {
        List {
            if isLoading && detail == nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    Button {
                        guard !songs.isEmpty else { return }
                        player.setQueue(songs, startIndex: 0, autoplay: true)
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.dynamicAccent)
                    .disabled(songs.isEmpty)
                    .listRowBackground(Color.clear)

                    Button {
                        saveLocalCopy()
                    } label: {
                        Label(didSaveCopy ? "Saved to Your Library" : "Save a Copy to Your Library", systemImage: didSaveCopy ? "checkmark" : "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(didSaveCopy ? AppTheme.success : AppTheme.dynamicAccent)
                    .disabled(songs.isEmpty || didSaveCopy)
                    .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)

                ForEach(songs) { song in
                    Button {
                        player.play(song: song, in: songs)
                    } label: {
                        SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppTheme.surface.opacity(0.5))
                }
            }
        }
        // `.plain`, not `.insetGrouped` — see FavoritesView's identical fix;
        // `.insetGrouped` splits each Section into a separate floating card
        // with the background showing fully through the gaps.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear.ignoresSafeArea())
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
        .task {
            isLoading = true
            detail = await account.fetchPlaylistDetail(playlistId: summary.id)
            isLoading = false
        }
    }

    private func saveLocalCopy() {
        guard !songs.isEmpty else { return }
        library.createPlaylist(name: summary.name)
        guard let newPL = library.playlists.last(where: { $0.name == summary.name }) else { return }
        for song in songs {
            // Ensure streamed/shared tracks the user doesn't have locally are
            // still referenceable — addSong just stores the ID, which is fine
            // for local-library matches; URL-only tracks are skipped here since
            // there's no durable local song record to point at.
            if library.songsByID[song.id] != nil {
                library.addSong(id: song.id, toPlaylistID: newPL.id)
            }
        }
        didSaveCopy = true
    }
}
