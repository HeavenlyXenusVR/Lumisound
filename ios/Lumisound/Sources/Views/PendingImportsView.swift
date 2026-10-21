import SwiftUI

// MARK: - PendingImportsView
//
// Visibility into the background download-recovery pipeline (see
// StreamingService+PendingDownloads.swift): what's currently sitting on the
// bridge finished-but-unfetched, and what was just auto-imported this
// session and where it landed. Auto-import keeps running exactly as before
// (launch/foreground/BGAppRefreshTask/silent push) — this screen doesn't
// replace that, it just makes it visible, and offers a manual per-item or
// "Import All" as a convenience for anyone who doesn't want to wait for the
// next automatic trigger.

struct PendingImportsView: View {
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var library: LibraryManager

    @State private var pending: [StreamingService.PendingDownloadInfo] = []
    @State private var isLoading = false
    @State private var isImportingAll = false

    var body: some View {
        List {
            if pending.isEmpty && streaming.recentImports.isEmpty && !isLoading {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 32))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("Nothing waiting")
                            .font(AppTheme.bodyFont(size: 15))
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Downloads that finish while the app is closed show up here automatically.")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            }

            if !pending.isEmpty {
                Section {
                    ForEach(pending, id: \.job_id) { entry in
                        PendingImportRow(entry: entry, isImportingAllDisabled: isImportingAll) { entry, folderOverride in
                            await importNow(entry, folderOverride: folderOverride)
                        }
                    }
                    Button {
                        Task { await importAll() }
                    } label: {
                        HStack {
                            Spacer()
                            if isImportingAll {
                                ProgressView()
                            } else {
                                Text("Import All")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isImportingAll)
                } header: {
                    Text("Pending (\(pending.count))")
                }
            }

            if !streaming.recentImports.isEmpty {
                Section {
                    ForEach(streaming.recentImports) { item in
                        recentImportRow(item)
                    }
                } header: {
                    Text("Recently Imported")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Pending Imports")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    // MARK: Rows

    @ViewBuilder
    private func recentImportRow(_ item: StreamingService.RecentImport) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(AppTheme.bodyFont(size: 14))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text((item.destinationFolder?.isEmpty == false ? item.destinationFolder : nil) ?? "Imported Music")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Text(item.importedAt, style: .relative)
                .font(AppTheme.bodyFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: Actions

    private func refresh() async {
        isLoading = true
        pending = await streaming.fetchPendingDownloads()
        isLoading = false
    }

    private func importNow(_ entry: StreamingService.PendingDownloadInfo, folderOverride: String?) async {
        guard await streaming.importPendingDownload(entry, folderOverride: folderOverride) else {
            ToastCenter.shared.show("Couldn't import \"\(entry.title ?? entry.filename)\"", category: .error)
            return
        }
        await library.scanLocalDocumentsAsync()
        await refresh()
    }

    private func importAll() async {
        isImportingAll = true
        defer { isImportingAll = false }
        await streaming.reconcilePendingDownloads()
        await refresh()
    }
}

/// Isolates one pending-download row — including its "Save to" folder
/// picker — from the rest of `PendingImportsView`.
///
/// Reported (same shape as the tracked-playlist "Save to" dropdown fix):
/// the folder picker here flickers/resets while open too. The row used to
/// read its folder override and "is this one importing" state from
/// dictionaries keyed by job_id on the PARENT (`folderOverrides`/
/// `importingJobIDs`) — so any parent re-render for an unrelated reason
/// (and `streaming`/`library` are both held broadly here, with plenty of
/// their own unrelated `@Published` churn from other features) rebuilt
/// every row's dropdown right along with it. Each row now owns its folder
/// override and importing state as its OWN local `@State`, seeded once at
/// init from `entry.destination_folder` — no parent dictionary lookup, so
/// nothing about this row depends on why the parent's body last ran.
/// `onImport` is the one thing it still needs from the parent: performing
/// the actual import needs `streaming`/`library`, which stay there.
private struct PendingImportRow: View {
    let entry: StreamingService.PendingDownloadInfo
    let isImportingAllDisabled: Bool
    let onImport: (StreamingService.PendingDownloadInfo, String?) async -> Void

    @State private var folderOverride: String
    @State private var isImporting = false

    init(entry: StreamingService.PendingDownloadInfo, isImportingAllDisabled: Bool, onImport: @escaping (StreamingService.PendingDownloadInfo, String?) async -> Void) {
        self.entry = entry
        self.isImportingAllDisabled = isImportingAllDisabled
        self.onImport = onImport
        _folderOverride = State(initialValue: entry.destination_folder ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? entry.filename)
                    .font(AppTheme.bodyFont(size: 15))
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if let artist = entry.artist, !artist.isEmpty {
                    Text(artist)
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            HStack {
                DownloadFolderPicker(folderName: $folderOverride)
                Spacer()
                Button {
                    Task {
                        isImporting = true
                        // Passed through as-is, including empty — importPendingDownload
                        // treats an empty string as "explicitly the Imported Music
                        // root" (same convention DownloadFolderPicker itself uses),
                        // distinct from nil ("no override, fall back to the entry's
                        // own destination_folder"). folderOverride here always
                        // reflects whatever the picker is currently showing — seeded
                        // from entry.destination_folder at init, so leaving it
                        // untouched reproduces the same resolved folder either way.
                        await onImport(entry, folderOverride)
                        isImporting = false
                    }
                } label: {
                    if isImporting {
                        ProgressView()
                    } else {
                        Label("Import Now", systemImage: "tray.and.arrow.down")
                            .font(AppTheme.bodyFont(size: 13))
                    }
                }
                .disabled(isImporting || isImportingAllDisabled)
            }
        }
        .padding(.vertical, 4)
    }
}
