import SwiftUI

extension SettingsView {

    // MARK: — Library Section

    var librarySection: some View {
        Section {
            // Library error message (if any)
            if let error = library.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Stats
            LabeledContent("Songs") {
                Text("\(library.allSongs.count)")
                    .font(AppTheme.monoFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .foregroundStyle(AppTheme.textPrimary)

            LabeledContent("Artists") {
                Text("\(library.artists.count)")
                    .font(AppTheme.monoFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .foregroundStyle(AppTheme.textPrimary)

            LabeledContent("Albums") {
                Text("\(library.albums.count)")
                    .font(AppTheme.monoFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .foregroundStyle(AppTheme.textPrimary)

            LabeledContent("Playlists") {
                Text("\(library.playlists.count)")
                    .font(AppTheme.monoFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .foregroundStyle(AppTheme.textPrimary)

            // Unified health scorecard — metadata/bitrate checks plus the two below
            NavigationLink(destination: LibraryHealthView()) {
                Label("Library Health", systemImage: "heart.text.square")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // Corrupt file finder
            NavigationLink(destination: CorruptFilesView()) {
                Label("Corrupt File Finder", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // Duplicate finder
            NavigationLink(destination: DuplicateFilesView()) {
                Label("Duplicate Finder", systemImage: "doc.on.doc")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // Playlist overlap/merge tool
            NavigationLink(destination: PlaylistMergeToolView()) {
                Label("Compare Playlists", systemImage: "rectangle.2.swap")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // Storage & cache manager
            NavigationLink(destination: CacheManagerView().environmentObject(cacheManager)) {
                Label("Storage & Cache", systemImage: "internaldrive")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // Local playlist/favorites backup — no server/account involved
            NavigationLink(destination: LibraryBackupView()) {
                Label("Backup & Restore", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // 30-day undo for deleted playlists — no server/account involved
            NavigationLink(destination: DeletedPlaylistsView()) {
                Label("Recently Deleted Playlists", systemImage: "trash")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // On-device listening stats — no server/account involved
            NavigationLink(destination: ListeningStatsView()) {
                Label("Listening Stats", systemImage: "chart.bar.fill")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // Wake-up alarm that fades in music — no server/account involved
            NavigationLink(destination: SleepWakeAlarmView()) {
                Label("Wake-Up Alarm", systemImage: "alarm")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // Force metadata sync
            Button {
                Task {
                    await library.forceMetadataSync(using: folderService, currentlyPlayingID: player.currentSong?.id)
                    // forceMetadataSync runs silently otherwise — without this the
                    // button just shows a brief spinner and nothing else, which is
                    // indistinguishable from doing nothing at all even though it
                    // really did rescan, re-tag, and re-enrich every track.
                    if let result = library.lastScanResult {
                        ToastCenter.shared.show(result, category: .success, icon: "checkmark.circle")
                        // Also a real device notification (gated by the
                        // "Background Scan & Import" toggle in Settings →
                        // Notifications) — this can run long enough that the
                        // user has switched away from the app entirely by the
                        // time it finishes, and the toast alone is silent to
                        // anyone not looking at this screen.
                        NotificationService.shared.notify(
                            title: "Library Sync Complete",
                            body: result,
                            identifier: "background-import-\(Date().timeIntervalSince1970)",
                            topic: "background_import"
                        )
                    }
                }
            } label: {
                HStack {
                    Label("Force Metadata Sync", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Spacer()
                    if library.isForcingMetadataSync {
                        ProgressView()
                            .tint(.pink)
                    }
                }
            }
            .disabled(library.isForcingMetadataSync)

        } header: {
            sectionHeader("Library", icon: "music.note.list", tint: .pink)
        } footer: {
            Text("Re-scans your entire Documents folder — including \"Imported Music\" and any subfolders — plus any watched folders, then re-reads embedded tags and re-runs online metadata lookups for every imported track. Use this if tags look stale or after manually adding files outside the app.")
                .font(AppTheme.bodyFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }
}
