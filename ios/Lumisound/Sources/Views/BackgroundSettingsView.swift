import SwiftUI
import PhotosUI
import UIKit

// MARK: - BackgroundSettingsView

struct BackgroundSettingsView: View {
    @EnvironmentObject var bg: BackgroundService
    @EnvironmentObject var account: AccountService
    @EnvironmentObject var streaming: StreamingService
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false

    @State private var cloudError: String?
    @State private var uploadingIndices: Set<Int> = []
    @AppStorage(GalleryBackgroundSource.storageKey) private var backgroundSource = GalleryBackgroundSource.photos.rawValue

    var body: some View {
        List {
            // MARK: Background Source
            //
            // Everything below this section (photo picker, cloud sync, shuffle
            // interval, transition animation) only applies to the Photos
            // source — Sonic Wallpaper is fully automatic (generated from the
            // user's own top-played/favorited artwork, see
            // `SonicWallpaperView`) and has nothing to configure, so it isn't
            // gated behind hiding/disabling the rest of this screen, just
            // called out with a note.
            Section {
                Picker("Background Source", selection: $backgroundSource) {
                    ForEach(GalleryBackgroundSource.allCases) { source in
                        Text(source.title).tag(source.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if backgroundSource == GalleryBackgroundSource.sonic.rawValue {
                    Text("Sonic Wallpaper is generated automatically from your own most-played and favorited tracks' artwork — nothing to add or configure. The photo settings below are ignored while it's selected.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                } else if backgroundSource == GalleryBackgroundSource.reactive.rawValue {
                    Text("Reactive Aura pulses live with whatever's playing — colored from the current track's artwork, driven directly by its bass/mid/treble energy in real time. Nothing to add or configure, and the photo settings below are ignored while it's selected.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            // MARK: Status + Start/Stop button
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bg.isEnabled && bg.isActive ? "Gallery Running" : bg.images.isEmpty ? "No images added" : "Gallery Paused")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(bg.isEnabled && bg.isActive ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                        if !bg.images.isEmpty {
                            Text("\(bg.images.count) image\(bg.images.count == 1 ? "" : "s") loaded")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    Spacer()
                    if !bg.images.isEmpty {
                        Button {
                            if bg.isEnabled && bg.isActive {
                                bg.isEnabled = false
                                bg.stopShuffling()
                                bg.saveSettings()
                            } else {
                                bg.isEnabled = true
                                bg.saveSettings()
                                bg.startShuffling()
                            }
                        } label: {
                            Text(bg.isEnabled && bg.isActive ? "Stop" : "Start")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .background(bg.isEnabled && bg.isActive ? AppTheme.error : AppTheme.dynamicAccent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.2), value: bg.isEnabled && bg.isActive)
                    }
                }
                .padding(.vertical, 4)

                // Preview current background image
                if bg.isEnabled, !bg.images.isEmpty {
                    AnimatedImageView(image: bg.images[bg.currentIndex % bg.images.count], contentMode: .scaleAspectFill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipped()
                        .cornerRadius(10)
                        .blur(radius: bg.blurRadius / 2, opaque: true)
                        .opacity(bg.opacity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppTheme.dynamicAccent.opacity(0.4), lineWidth: 1)
                        )
                }
            }

            // MARK: Image Picker Section
            Section("Images (\(bg.images.count) saved)") {
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 150,
                    matching: .images
                ) {
                    HStack {
                        Label("Add from Photo Library", systemImage: "photo.on.rectangle.angled")
                            .foregroundStyle(AppTheme.dynamicAccent)
                        Spacer()
                        if isLoadingPhotos {
                            ProgressView()
                                .tint(AppTheme.dynamicAccent)
                        }
                    }
                }
                .onChange(of: selectedItems) { items in
                    guard !items.isEmpty else { return }
                    isLoadingPhotos = true
                    Task {
                        var loadedImages: [UIImage] = []
                        var loadedIDs: [String?] = []
                        var loadedGIFData: [Data?] = []
                        var duplicateCount = 0
                        for item in items {
                            // Skip photos already in the gallery rather than
                            // re-adding a duplicate — the system picker itself
                            // can't be told which assets to hide, so this is a
                            // post-selection filter instead.
                            if let identifier = item.itemIdentifier, bg.isAssetAlreadyAdded(identifier) {
                                duplicateCount += 1
                                continue
                            }
                            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                            if isGIFData(data), let animated = UIImage.gifImage(data: data, maxDimension: 1280) {
                                // Keep GIFs animated (unlike the downsample
                                // path below, which flattens to a single
                                // static frame) but still cap each frame to
                                // the same 1280px used for static photos —
                                // an un-downsampled multi-frame GIF from the
                                // real Photos library can be many MB of fully
                                // decoded bitmaps per image, and with a
                                // gallery holding 100+ of these the continuous
                                // animate+blur compositing of even just the
                                // one currently-displayed image was enough to
                                // saturate the main thread and make the rest
                                // of this screen appear to never render.
                                loadedImages.append(animated)
                                loadedIDs.append(item.itemIdentifier)
                                loadedGIFData.append(data)
                            } else if let image = BackgroundService.downsampledImage(from: data, maxDimension: 1280) {
                                loadedImages.append(image)
                                loadedIDs.append(item.itemIdentifier)
                                loadedGIFData.append(nil)
                            } else if let image = UIImage(data: data) {
                                loadedImages.append(image)
                                loadedIDs.append(item.itemIdentifier)
                                loadedGIFData.append(nil)
                            }
                        }
                        await MainActor.run {
                            if !loadedImages.isEmpty {
                                bg.addImages(loadedImages, assetIDs: loadedIDs, gifDataList: loadedGIFData)
                            }
                            if duplicateCount > 0 {
                                ToastCenter.shared.show(
                                    "Skipped \(duplicateCount) photo\(duplicateCount == 1 ? "" : "s") already in your gallery",
                                    category: .info,
                                    icon: "photo.badge.checkmark"
                                )
                            }
                            selectedItems = []
                            isLoadingPhotos = false
                        }
                    }
                }

                if !bg.images.isEmpty {
                    Button(role: .destructive) {
                        bg.clearAll()
                    } label: {
                        Label("Clear All Images", systemImage: "trash")
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        // LazyHStack + small thumbnails (not the full ~1280px
                        // slideshow images) — with a large gallery (100+
                        // photos), eagerly laying out every full-size bitmap
                        // in a plain HStack is what made this screen grind to
                        // a halt well before any hard limit was ever reached.
                        LazyHStack(spacing: 8) {
                            ForEach(bg.images.indices, id: \.self) { i in
                                Image(uiImage: bg.thumbnails.indices.contains(i) ? bg.thumbnails[i] : bg.images[i])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            bg.removeImage(at: i)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.white)
                                                .background(Color.black.opacity(0.5), in: Circle())
                                                .font(.caption)
                                        }
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        if i == bg.currentIndex && bg.isEnabled {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(AppTheme.dynamicAccent)
                                                .background(Color.black.opacity(0.5), in: Circle())
                                                .font(.caption)
                                                .padding(3)
                                        }
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        if account.isLoggedIn, let token = account.token {
                                            Button {
                                                uploadToCloud(bg.images[i], index: i, token: token)
                                            } label: {
                                                if uploadingIndices.contains(i) {
                                                    ProgressView()
                                                        .tint(.white)
                                                        .scaleEffect(0.6)
                                                        .frame(width: 16, height: 16)
                                                        .background(Color.black.opacity(0.5), in: Circle())
                                                } else {
                                                    Image(systemName: "icloud.and.arrow.up.fill")
                                                        .foregroundStyle(.white)
                                                        .background(Color.black.opacity(0.5), in: Circle())
                                                        .font(.caption)
                                                }
                                            }
                                            .disabled(uploadingIndices.contains(i))
                                            .padding(3)
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            // MARK: Cloud Backup Section
            Section("Cloud Backup") {
                if account.isLoggedIn, let token = account.token {
                    if let error = cloudError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppTheme.error)
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.error)
                            Spacer()
                            Button {
                                cloudError = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                    }

                    Button {
                        refreshCloudGallery(token: token)
                    } label: {
                        HStack {
                            Label(
                                streaming.galleryImages.isEmpty
                                    ? "Synced Images"
                                    : "Synced Images (\(streaming.galleryImages.count))",
                                systemImage: "icloud"
                            )
                            .foregroundStyle(AppTheme.dynamicAccent)
                            Spacer()
                            if streaming.isLoadingGallery {
                                ProgressView().tint(AppTheme.dynamicAccent)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                    }
                    .disabled(streaming.isLoadingGallery)

                    if streaming.galleryImages.isEmpty {
                        Text(streaming.isLoadingGallery
                             ? "Loading your synced images…"
                             : "No images backed up yet. Tap the cloud icon on a local image to back it up.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(streaming.galleryImages) { cloudImage in
                                    CloudGalleryThumbnail(image: cloudImage, token: token) { downloaded in
                                        bg.addImages([downloaded])
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    Text("Log in from Settings → Account to back up your gallery images to the cloud and sync them across devices.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .onAppear {
                if account.isLoggedIn, let token = account.token,
                   streaming.galleryImages.isEmpty, !streaming.isLoadingGallery {
                    refreshCloudGallery(token: token)
                }
            }

            // Show settings as soon as images exist (not just when enabled)
            if !bg.images.isEmpty {

                // MARK: Shuffle Interval Section
                Section("Shuffle Interval") {
                    Picker("Interval", selection: $bg.shuffleIntervalSeconds) {
                        ForEach(BackgroundService.intervalPresets, id: \.seconds) { p in
                            Text(p.label).tag(p.seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(AppTheme.dynamicAccent)
                    .onChange(of: bg.shuffleIntervalSeconds) { _ in
                        bg.saveSettings()
                        bg.startShuffling()
                    }
                }

                // MARK: Animation Section
                Section("Transition Animation") {
                    LazyVGrid(
                        columns: Array(repeating: .init(.flexible()), count: 4),
                        spacing: 12
                    ) {
                        ForEach(BackgroundAnimation.allCases) { anim in
                            VStack(spacing: 4) {
                                Image(systemName: anim.sfSymbol)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        bg.animation == anim ? AppTheme.dynamicAccent : AppTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .foregroundStyle(
                                        bg.animation == anim ? .white : AppTheme.textSecondary
                                    )
                                Text(anim.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .onTapGesture {
                                bg.animation = anim
                                bg.saveSettings()
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                // MARK: Preview Section
                Section {
                    Button {
                        bg.nextImage()
                    } label: {
                        Label("Preview Next Image", systemImage: "photo.on.rectangle")
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                    .disabled(bg.images.count < 2)
                }

                // MARK: Appearance Section
                Section("Appearance") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Opacity")
                            Spacer()
                            Text(String(format: "%.0f%%", bg.opacity * 100))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Slider(value: $bg.opacity, in: 0.05...0.8)
                            .tint(AppTheme.dynamicAccent)
                            .onChange(of: bg.opacity) { _ in bg.saveSettings() }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Blur")
                            Spacer()
                            Text(bg.blurRadius == 0 ? "Off" : String(format: "%.0f", bg.blurRadius))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Slider(value: $bg.blurRadius, in: 0...40)
                            .tint(AppTheme.dynamicAccent)
                            .onChange(of: bg.blurRadius) { _ in bg.saveSettings() }
                    }

                    Toggle(isOn: $bg.kenBurnsEnabled) {
                        Label("Ken Burns Motion", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }
        }
        // Applied to the List so every row inherits it — unlike the other
        // Settings screens this one never set a row background at all, so its
        // rows rendered fully transparent straight onto the gallery image
        // behind them. That was survivable while it was the odd one out; now
        // that every screen around it is glass it just reads as a screen that
        // failed to draw. Rows that deliberately opt out (the full-bleed photo
        // strip below) still override this with their own `Color.clear`.
        // `.purple` matches the Appearance section that pushes this screen.
        .listRowBackground(tintedRowBackground(.purple))
        .scrollContentBackground(.hidden)
        .background(Color.clear.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar()
        }
        .navigationTitle("Gallery Background")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cloud Sync Actions

    private func refreshCloudGallery(token: String) {
        cloudError = nil
        Task {
            do {
                _ = try await streaming.fetchGalleryImages(token: token)
            } catch {
                await MainActor.run { cloudError = error.localizedDescription }
            }
        }
    }

    private func uploadToCloud(_ image: UIImage, index: Int, token: String) {
        uploadingIndices.insert(index)
        cloudError = nil
        Task {
            do {
                _ = try await streaming.uploadGalleryImage(image, token: token, displayOrder: index)
            } catch {
                await MainActor.run { cloudError = "Upload failed: \(error.localizedDescription)" }
            }
            await MainActor.run { uploadingIndices.remove(index) }
        }
    }
}

// MARK: - CloudGalleryThumbnail

/// A single cloud-synced gallery entry — lazily fetches its bytes (the file-serving
/// endpoint requires the user's bearer token, so it can't be loaded via AsyncImage),
/// and offers download-to-local and delete-from-cloud actions.
private struct CloudGalleryThumbnail: View {
    let image: GalleryImageInfo
    let token: String
    let onDownload: (UIImage) -> Void

    @EnvironmentObject private var streaming: StreamingService
    @State private var thumbnail: UIImage?
    @State private var isDeleting = false
    @State private var deleteFailed = false

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.surface)
                    .overlay { ProgressView().tint(AppTheme.dynamicAccent) }
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isDeleting ? 0.4 : 1)
        .overlay(alignment: .topTrailing) {
            Button {
                deleteFromCloud()
            } label: {
                Image(systemName: deleteFailed ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .foregroundStyle(deleteFailed ? AppTheme.error : .white)
                    .background(Color.black.opacity(0.5), in: Circle())
                    .font(.caption)
            }
            .disabled(isDeleting)
        }
        .overlay(alignment: .bottomLeading) {
            if let thumbnail {
                Button {
                    onDownload(thumbnail)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.5), in: Circle())
                        .font(.caption)
                }
                .padding(3)
            }
        }
        .task {
            guard thumbnail == nil else { return }
            thumbnail = await streaming.fetchGalleryImageData(image, token: token)
        }
    }

    private func deleteFromCloud() {
        isDeleting = true
        deleteFailed = false
        Task {
            do {
                try await streaming.deleteGalleryImage(id: image.id, token: token)
            } catch {
                await MainActor.run {
                    isDeleting = false
                    deleteFailed = true
                }
            }
        }
    }
}
