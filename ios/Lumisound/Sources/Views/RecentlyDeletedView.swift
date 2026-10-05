import SwiftUI

/// Lists songs removed via `LibraryManager.removeImportedSong(s)` that are
/// still within their 30-day recovery window (see `RecentlyDeletedService`),
/// with per-track restore, a bulk "Restore All" (recovering from a mass
/// false-positive delete — e.g. an autonomous scanner mis-flagging an entire
/// class of files — without tapping Restore hundreds of times), and a bulk
/// "Delete All" for permanently clearing the trash early.
struct RecentlyDeletedView: View {

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var trash: RecentlyDeletedService

    @State private var showEmptyTrashConfirm = false
    @State private var showRestoreAllConfirm = false

    private var sortedEntries: [RecentlyDeletedService.Entry] {
        trash.entries.sorted { $0.deletedAt > $1.deletedAt }
    }

    var body: some View {
        List {
            if sortedEntries.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("Nothing in Recently Deleted")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(sortedEntries) { entry in
                        row(for: entry)
                    }
                } footer: {
                    Text("Deleted tracks are kept for 30 days before being permanently removed.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(EditionScreenBackground())
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !sortedEntries.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Restore All") {
                        showRestoreAllConfirm = true
                    }
                    .tint(AppTheme.dynamicAccent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Delete All", role: .destructive) {
                        showEmptyTrashConfirm = true
                    }
                }
            }
        }
        // This view is pushed from Settings → Downloads, which sits behind
        // ContentView's own floating CustomTabBar (its .safeAreaInset lives
        // on ContentView's outer Group, so it persists across every pushed
        // screen in that branch) — without reserving space for it here, the
        // last rows of a long list (this list can genuinely run into the
        // thousands after a mass false-positive delete) scroll in UNDER the
        // bar, hiding their swipe-to-delete-forever action behind it. Same
        // fix every other list screen in the app already uses (Favorites,
        // Folder Detail, etc.) — MiniPlayerBar reserves exactly
        // CustomTabBar.totalHeight of extra bottom clearance for free.
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar()
        }
        .confirmationDialog(
            "Restore All \(sortedEntries.count) Track\(sortedEntries.count == 1 ? "" : "s")?",
            isPresented: $showRestoreAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore All") {
                let restored = trash.restoreAll()
                for song in restored {
                    library.readdRestoredSong(song)
                }
                let word = restored.count == 1 ? "track" : "tracks"
                ToastCenter.shared.show("Restored \(restored.count) \(word)", category: .success, icon: "arrow.uturn.backward")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moves every track here back into your library.")
        }
        .confirmationDialog(
            "Permanently Delete All?",
            isPresented: $showEmptyTrashConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                trash.purgeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder
    private func row(for entry: RecentlyDeletedService.Entry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.song.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text("\(entry.song.artistName) · \(daysRemainingText(entry))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                if let restored = trash.restore(entryID: entry.id) {
                    library.readdRestoredSong(restored)
                    ToastCenter.shared.show("Restored \"\(restored.displayName)\"", category: .success, icon: "arrow.uturn.backward")
                } else {
                    ToastCenter.shared.show("Couldn't restore that track", category: .error)
                }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.dynamicAccent)
        }
        .listRowBackground(AppTheme.surface)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                trash.purge(entryID: entry.id)
            } label: {
                Label("Delete Forever", systemImage: "trash")
            }
        }
    }

    private func daysRemainingText(_ entry: RecentlyDeletedService.Entry) -> String {
        let expiresAt = entry.deletedAt.addingTimeInterval(RecentlyDeletedService.retentionInterval)
        let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0)
        return days <= 0 ? "Expires today" : "\(days) day\(days == 1 ? "" : "s") left"
    }
}
