import SwiftUI
import UniformTypeIdentifiers

/// Settings screen for the local playlist/favorites backup feature —
/// entirely on-device, no server/account involved. Exports a JSON snapshot
/// of playlist structure + favorites for sharing (AirDrop, Files, Messages,
/// etc.) and can re-import one later, e.g. after a reinstall or on a new
/// device that already has the same songs imported/synced via iCloud Music
/// Library.
struct LibraryBackupView: View {
    @EnvironmentObject private var library: LibraryManager

    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var showImporter = false
    @State private var importErrorMessage: String?

    /// Plain, pre-computed string (rather than a multi-ternary interpolation
    /// inline in a `Text(...)` call) — kept simple deliberately after a
    /// sibling screen (`CacheManagerView`) hit a Swift type-checker timeout
    /// from too much inline ViewBuilder complexity in one `body`.
    private var exportFooterText: String {
        let playlistWord = library.playlists.count == 1 ? "playlist" : "playlists"
        let favoriteWord = library.favoriteSongIDs.count == 1 ? "favorite" : "favorites"
        return "Saves your \(library.playlists.count) \(playlistWord) and \(library.favoriteSongIDs.count) \(favoriteWord) to a single file you can AirDrop, save to Files, or send to yourself."
    }

    var body: some View {
        List {
            exportSection
            importSection
            infoSection
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let exportURL {
                RewindShareSheet(items: [exportURL])
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImportResult(result)
        }
        .alert("Import Failed", isPresented: .constant(importErrorMessage != nil), presenting: importErrorMessage) { _ in
            Button("OK") { importErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                Label("Export Backup", systemImage: "square.and.arrow.up")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .disabled(library.playlists.isEmpty && library.favoriteSongIDs.isEmpty)
        } header: {
            sectionHeader("Export")
        } footer: {
            Text(exportFooterText)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var importSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down")
                    .foregroundStyle(AppTheme.textPrimary)
            }
        } header: {
            sectionHeader("Import")
        } footer: {
            Text("Adds the playlists and favorites from a backup file to what you already have here — nothing existing is replaced or removed. Songs the backup references that aren't in your library on this device are skipped.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var infoSection: some View {
        Section {
            Label("Doesn't include audio files", systemImage: "info.circle")
                .foregroundStyle(AppTheme.textSecondary)
                .font(.caption)
        } footer: {
            Text("This backs up playlist structure and favorites only — not the actual song files. Apple Music library songs need iCloud Music Library on both devices; imported/downloaded files need to be transferred separately.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(Color.clear)
    }

    private func exportBackup() {
        appLog("LibraryBackupView: user tapped Export Backup", category: "library")
        let backup = LibraryBackup(playlists: library.playlists, favoriteSongIDs: library.favoriteSongIDs)
        do {
            exportURL = try LibraryBackupService.exportBackup(backup)
            showShareSheet = true
        } catch {
            appError("LibraryBackupView: export failed: \(error.localizedDescription)", category: "library")
            importErrorMessage = "Couldn't create the backup file. Please try again."
        }
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            appWarn("LibraryBackupView: file importer failed: \(error.localizedDescription)", category: "library")
            importErrorMessage = "Couldn't read that file."
        case .success(let url):
            appLog("LibraryBackupView: user picked \(url.lastPathComponent) to import", category: "library")
            do {
                let backup = try LibraryBackupService.decodeBackup(from: url)
                let (imported, skipped) = library.importBackup(backup)
                let skippedText = skipped > 0 ? ", \(skipped) song\(skipped == 1 ? "" : "s") skipped (not in your library)" : ""
                ToastCenter.shared.show(
                    "Imported \(imported) playlist\(imported == 1 ? "" : "s")\(skippedText)",
                    category: .success,
                    icon: "square.and.arrow.down"
                )
            } catch {
                appError("LibraryBackupView: import failed for \(url.lastPathComponent): \(error.localizedDescription)", category: "library")
                importErrorMessage = "That file doesn't look like a Lumisound backup."
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
