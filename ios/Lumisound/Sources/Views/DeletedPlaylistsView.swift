import SwiftUI

/// A 30-day recovery list for deleted playlists — see
/// `DeletedPlaylistsStore`'s doc comment. Same "swipe to restore or delete
/// forever" shape as the Downloads Manager's Recently Deleted screen.
struct DeletedPlaylistsView: View {
    @EnvironmentObject private var library: LibraryManager
    @ObservedObject private var store = DeletedPlaylistsStore.shared

    var body: some View {
        List {
            if store.entries.isEmpty {
                EmptyStateView(
                    icon: "trash",
                    title: "Nothing Here",
                    message: "Deleted playlists stay here for 30 days before being purged for good."
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(store.entries) { entry in
                        entryRow(entry)
                    }
                } footer: {
                    Text("Deleted playlists are kept for 30 days, then purged automatically.")
                }
                .listRowBackground(tintedRowBackground(.pink))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Recently Deleted Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.entries.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        store.purgeAll()
                    } label: {
                        Text("Delete All")
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: DeletedPlaylistEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.playlist.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("\(entry.playlist.songCount) song\(entry.playlist.songCount == 1 ? "" : "s") · deleted \(relativeDate(entry.deletedAt))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.purge(entryID: entry.id)
            } label: {
                Label("Delete Forever", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                restore(entry)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(AppTheme.dynamicAccent)
        }
    }

    private func restore(_ entry: DeletedPlaylistEntry) {
        guard let playlist = store.restore(entryID: entry.id) else { return }
        library.restorePlaylist(playlist)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
