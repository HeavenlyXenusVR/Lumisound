import SwiftUI

// MARK: - TVPlaylistsView (synced playlists — GET /user/playlists)
//
// A playlist's tracks come from whichever device(s) added them and may point
// at an on-device library item (`local_song_id`) instead of a stream URL —
// tvOS has no local file/media library access at all (see
// TVOS_WATCHOS_FEASIBILITY.md), so those entries are shown but not playable
// here. Entries backed by a Personal Cloud Library upload carry the bridge's
// own `/user/music/stream` URL as `track_url` and play like any other track.
//
// Create/rename/delete/add/remove all go through the bridge's dedicated
// playlist-mutation endpoints (not the wholesale `/user/sync` snapshot push,
// which would also overwrite the user's other settings) — see
// `TVBridgeClient`'s "Playlist mutations" section.

struct TVPlaylistsView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    private var columns: [GridItem] { TVGridLayout.columns() }
    @State private var showNewPlaylist = false
    @State private var renamingPlaylist: TVPlaylist?

    var body: some View {
        ScrollView {
            if client.isLoadingPlaylists {
                ProgressView("Loading your playlists…").padding(.top, 100)
            } else if let err = client.playlistsError {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.icloud").font(.system(size: 70)).foregroundStyle(.secondary)
                    Text(err).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { Task { await client.fetchPlaylists(token: token) } }
                        .frame(width: 260)
                }
                .padding(.top, 100)
            } else if client.playlists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list").font(.system(size: 70)).foregroundStyle(.secondary)
                    Text("No playlists yet.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    newPlaylistButton
                }
                .padding(.top, 120)
            } else {
                VStack(alignment: .leading, spacing: 40) {
                    if let featured = client.playlists.first, !featured.tracks.isEmpty {
                        featuredHero(featured)
                    }

                    let rest = client.playlists.first?.tracks.isEmpty == false
                        ? Array(client.playlists.dropFirst())
                        : client.playlists
                    LazyVGrid(columns: columns, spacing: 48) {
                        newPlaylistCard
                        ForEach(rest) { playlist in
                            NavigationLink {
                                TVPlaylistDetailView(client: client, token: token, playlist: playlist)
                            } label: {
                                playlistCard(playlist)
                            }
                            .buttonStyle(.card)
                            .contextMenu {
                                Button {
                                    renamingPlaylist = playlist
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task { await client.deletePlaylist(id: playlist.id, token: token) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 60)
                }
                .padding(.vertical, 50)
            }
        }
        .task {
            if client.playlists.isEmpty { await client.fetchPlaylists(token: token) }
        }
        .sheet(isPresented: $showNewPlaylist) {
            TVPlaylistNameSheet(title: "New Playlist", initialName: "") { name in
                _ = await client.createPlaylist(name: name, token: token)
            }
        }
        .sheet(item: $renamingPlaylist) { playlist in
            TVPlaylistNameSheet(title: "Rename Playlist", initialName: playlist.name) { name in
                _ = await client.renamePlaylist(id: playlist.id, name: name, token: token)
            }
        }
    }

    private var newPlaylistButton: some View {
        Button {
            showNewPlaylist = true
        } label: {
            Label("New Playlist", systemImage: "plus")
        }
        .buttonStyle(.card)
    }

    private var newPlaylistCard: some View {
        Button {
            showNewPlaylist = true
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    Image(systemName: "plus").font(.system(size: 50)).foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                Text("New Playlist").font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.card)
    }

    /// A big top-of-screen treatment for the first (most recently created)
    /// playlist — same `TVHeroBanner` component the Home hub uses, so
    /// Playlists doesn't read as "just a grid" either.
    private func featuredHero(_ playlist: TVPlaylist) -> some View {
        let queue = playlist.tracks.compactMap { client.playable(from: $0, token: token) }
        return Group {
            if let first = queue.first {
                TVHeroBanner(
                    eyebrow: "Featured Playlist",
                    title: playlist.name,
                    subtitle: "\(playlist.tracks.count) \(playlist.tracks.count == 1 ? "song" : "songs")",
                    art: {
                        TVArtPlaceholder(systemImage: "music.note.list", iconScale: 2.4)
                    },
                    playButton: {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 24, weight: .bold))
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.card)
                    }
                )
            }
        }
    }

    private func playlistCard(_ playlist: TVPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TVArtPlaceholder(systemImage: "music.note.list", iconScale: 1.15)
                .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Text(playlist.name).font(.headline).lineLimit(2, reservesSpace: true)
            Text("\(playlist.tracks.count) \(playlist.tracks.count == 1 ? "song" : "songs")")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(width: 280)
    }
}

// MARK: - Playlist detail

struct TVPlaylistDetailView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let playlist: TVPlaylist

    /// Re-reads the live copy out of `client.playlists` so a track removal
    /// (which mutates that array) is reflected here without a separate fetch.
    private var current: TVPlaylist {
        client.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    /// Only remotely-playable tracks form the actual playback queue; a track
    /// that isn't playable here is skipped over entirely rather than queued
    /// and immediately failing.
    private var queue: [TVPlayable] {
        current.tracks.compactMap { client.playable(from: $0, token: token) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(current.name).font(.system(size: 40, weight: .bold))
                    if let description = current.description, !description.isEmpty {
                        Text(description).font(.title3).foregroundStyle(.secondary)
                    }
                    if let first = queue.first {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.card)
                        .padding(.top, 10)
                    }
                }

                if current.tracks.isEmpty {
                    Text("This playlist is empty.").font(.title3).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(current.tracks) { track in
                            row(for: track)
                        }
                    }
                }
            }
            .padding(TVMetrics.margin)
        }
        .tvAmbientBackground()
    }

    @ViewBuilder
    private func row(for track: TVPlaylistTrack) -> some View {
        let content = HStack(spacing: 24) {
            Image(systemName: track.isRemotelyPlayable ? "music.note" : "iphone.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.title3)
                Text(track.artist?.isEmpty == false ? track.artist! : "Unknown Artist")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !track.isRemotelyPlayable {
                Text("Not available on Apple TV")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())

        Group {
            if track.isRemotelyPlayable, let playable = client.playable(from: track, token: token) {
                NavigationLink(value: TVPlayContext(queue: queue, startID: playable.id)) {
                    content
                }
                .buttonStyle(.card)
            } else {
                content.opacity(0.5)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await client.removeTrack(track.id, fromPlaylist: playlist.id, token: token) }
            } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
        }
    }
}

// MARK: - TVPlaylistNameSheet
//
// Shared name-entry sheet for both create and rename. A plain `TextField` in
// a `List` (not a `TextField` embedded in `.alert`, which tvOS's on-screen
// keyboard flow doesn't drive reliably) — same pattern as the "New Playlist"
// row in `TVAddToPlaylistSheet`.

struct TVPlaylistNameSheet: View {
    let title: String
    let initialName: String
    let onSave: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            List {
                TextField("Playlist name", text: $name)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            await onSave(name.trimmingCharacters(in: .whitespaces))
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { name = initialName }
    }
}
