import SwiftUI

struct CacheManagerView: View {

    @EnvironmentObject private var cacheManager: CacheManagerService
    @EnvironmentObject private var library: LibraryManager
    @State private var showClearArtworkConfirm = false
    @State private var showClearTempConfirm = false
    @State private var showClearAllConfirm = false
    @State private var showClearArtistImagesConfirm = false
    @State private var showClearTranscodeConfirm = false
    @State private var showDeleteOrphansConfirm = false
    @State private var savedBytes: Int64 = 0
    @State private var showSavedBanner = false

    /// Each cache category's `Section` is its own computed property (rather
    /// than all inline in one `List { ... }`) — with 8 sections' worth of
    /// nested HStack/VStack/Button/Label content, the Swift type-checker
    /// timed out trying to infer the whole `body` as a single expression
    /// ("unable to type-check this expression in reasonable time"). Breaking
    /// it up gives the checker a much smaller expression to solve per piece.
    var body: some View {
        List {
            artworkCacheSection
            tempFilesSection
            artistImageSection
            transcodeSection
            orphanedFilesSection
            downloadedMusicSection
            bridgeCacheSection
            clearAllSection
            savedBannerSection
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Storage & Cache")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if cacheManager.isScanning {
                    ProgressView().tint(AppTheme.dynamicAccent)
                } else {
                    Button {
                        Task { await cacheManager.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }
        }
        .onAppear {
            cacheManager.scanOnAppear()
            Task {
                let known = Set(library.allSongs.compactMap { $0.url?.lastPathComponent })
                await cacheManager.scanOrphans(knownFilenames: known)
            }
        }
        .confirmationDialog(
            "Clear Artwork Cache?",
            isPresented: $showClearArtworkConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let freed = cacheManager.artworkCacheSize
                cacheManager.clearArtworkCache()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Album art will be re-downloaded as you browse your library.")
        }
        .confirmationDialog(
            "Clear Temp Files?",
            isPresented: $showClearTempConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let freed = cacheManager.tempFilesSize
                cacheManager.clearTempFiles()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Partial download folders will be deleted. Do not clear while a download is in progress.")
        }
        .confirmationDialog(
            "Clear Artist Photo Cache?",
            isPresented: $showClearArtistImagesConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let freed = cacheManager.artistImageCacheSize
                cacheManager.clearArtistImageCache()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Artist photos will be re-fetched from Deezer as you browse.")
        }
        .confirmationDialog(
            "Clear Transcode Cache?",
            isPresented: $showClearTranscodeConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let freed = cacheManager.transcodeCacheSize
                cacheManager.clearTranscodeCache()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Temporary audio-conversion files will be deleted. Do not clear while fingerprinting or exporting a track.")
        }
        .confirmationDialog(
            "Delete Orphaned Files?",
            isPresented: $showDeleteOrphansConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let freed = cacheManager.orphanedFilesSize
                cacheManager.deleteOrphanedFiles()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These files aren't referenced by anything in your library and will be permanently deleted.")
        }
        .confirmationDialog(
            "Clear All Cache?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                let freed = totalClearableSize
                cacheManager.clearAll()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Album art, artist photos, temp downloads, and transcode work files will all be cleared/re-fetched as needed. Your downloaded music and orphaned files are not affected — orphaned files must be deleted separately above.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var artworkCacheSection: some View {
        Section {
            HStack {
                Label("Cached Images", systemImage: "photo.on.rectangle.angled")
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(CacheManagerService.formattedSize(cacheManager.artworkCacheSize))
                        .font(AppTheme.monoFont(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text("\(cacheManager.artworkCacheCount) files")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            Button(role: .destructive) {
                showClearArtworkConfirm = true
            } label: {
                Label("Clear Artwork Cache", systemImage: "trash")
                    .foregroundStyle(AppTheme.error)
            }
            .disabled(cacheManager.artworkCacheSize == 0)
        } header: {
            sectionHeader("Artwork Cache")
        } footer: {
            Text("Album art thumbnails stored on disk for fast loading. Safe to clear — art is re-fetched as needed.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var tempFilesSection: some View {
        Section {
            HStack {
                Label("Temp Downloads", systemImage: "arrow.down.circle.dotted")
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(CacheManagerService.formattedSize(cacheManager.tempFilesSize))
                    .font(AppTheme.monoFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Button(role: .destructive) {
                showClearTempConfirm = true
            } label: {
                Label("Clear Temp Files", systemImage: "trash")
                    .foregroundStyle(AppTheme.error)
            }
            .disabled(cacheManager.tempFilesSize == 0)
        } header: {
            sectionHeader("Temporary Files")
        } footer: {
            Text("Partial download folders left behind if a stream download was interrupted. Safe to clear when not actively downloading.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var artistImageSection: some View {
        Section {
            HStack {
                Label("Artist Photos", systemImage: "person.crop.square")
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(CacheManagerService.formattedSize(cacheManager.artistImageCacheSize))
                        .font(AppTheme.monoFont(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text("\(cacheManager.artistImageCacheCount) files")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            Button(role: .destructive) {
                showClearArtistImagesConfirm = true
            } label: {
                Label("Clear Artist Photo Cache", systemImage: "trash")
                    .foregroundStyle(AppTheme.error)
            }
            .disabled(cacheManager.artistImageCacheSize == 0)
        } header: {
            sectionHeader("Artist Photos")
        } footer: {
            Text("Artist profile pictures fetched from Deezer, stored on disk for fast loading. Safe to clear — re-fetched as needed.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var transcodeSection: some View {
        Section {
            HStack {
                Label("Transcode Work Files", systemImage: "waveform")
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(CacheManagerService.formattedSize(cacheManager.transcodeCacheSize))
                    .font(AppTheme.monoFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Button(role: .destructive) {
                showClearTranscodeConfirm = true
            } label: {
                Label("Clear Transcode Cache", systemImage: "trash")
                    .foregroundStyle(AppTheme.error)
            }
            .disabled(cacheManager.transcodeCacheSize == 0)
        } header: {
            sectionHeader("Transcode Cache")
        } footer: {
            Text("Temporary files created while converting audio formats (e.g. AcoustID fingerprinting, format export). Safe to clear when nothing is actively processing.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var orphanedFilesSection: some View {
        Section {
            HStack {
                Label("Orphaned Files", systemImage: "questionmark.folder")
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                if cacheManager.isScanningOrphans {
                    ProgressView().tint(AppTheme.dynamicAccent)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CacheManagerService.formattedSize(cacheManager.orphanedFilesSize))
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("\(cacheManager.orphanedFiles.count) files")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }

            if !cacheManager.orphanedFiles.isEmpty {
                Button(role: .destructive) {
                    showDeleteOrphansConfirm = true
                } label: {
                    Label("Delete Orphaned Files", systemImage: "trash")
                        .foregroundStyle(AppTheme.error)
                }
            }
        } header: {
            sectionHeader("Orphaned Files")
        } footer: {
            Text("Files sitting in Imported Music that nothing in your library currently references — leftovers from a removed song, or files added outside the app. Not counted above; scanned separately since it needs to check against your library.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var downloadedMusicSection: some View {
        Section {
            NavigationLink {
                DownloadsManagementView()
            } label: {
                HStack {
                    Label("Imported Music", systemImage: "music.note")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(CacheManagerService.formattedSize(cacheManager.downloadedMusicSize))
                        .font(AppTheme.monoFont(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        } header: {
            sectionHeader("Downloaded Music")
        } footer: {
            Text("Tap to see every downloaded track's size, sort by size or date, and remove individual or multiple tracks at once.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var bridgeCacheSection: some View {
        Section {
            HStack {
                Label("Bridge Server Cache", systemImage: "server.rack")
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text("Managed on server")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        } header: {
            sectionHeader("Remote")
        } footer: {
            Text("yt-dlp streaming cache is stored server-side and managed automatically.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    private var totalClearableSize: Int64 {
        cacheManager.artworkCacheSize + cacheManager.tempFilesSize
            + cacheManager.artistImageCacheSize + cacheManager.transcodeCacheSize
    }

    @ViewBuilder
    private var clearAllSection: some View {
        if totalClearableSize > 0 {
            Section {
                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Label("Clear All Cache", systemImage: "trash")
                        .foregroundStyle(AppTheme.error)
                }
            } header: {
                sectionHeader("Actions")
            } footer: {
                Text("Clears all cache categories above in one tap (\(CacheManagerService.formattedSize(totalClearableSize))). Your downloaded music is never affected.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .listRowBackground(tintedRowBackground(.pink))
        }
    }

    @ViewBuilder
    private var savedBannerSection: some View {
        if showSavedBanner {
            Section {
                Label("\(CacheManagerService.formattedSize(savedBytes)) freed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
            }
            .listRowBackground(Color.clear)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    private func flashSavedBanner(bytes: Int64) {
        guard bytes > 0 else { return }
        savedBytes = bytes
        withAnimation { showSavedBanner = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { showSavedBanner = false }
        }
    }
}
