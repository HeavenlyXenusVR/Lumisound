import Foundation
import UIKit
import PhotosUI
import SwiftUI

// MARK: - BackgroundAnimation

enum BackgroundAnimation: String, CaseIterable, Codable, Identifiable {
    case fade       = "Fade"
    case slideLeft  = "Slide Left"
    case slideRight = "Slide Right"
    case slideUp    = "Slide Up"
    case slideDown  = "Slide Down"
    case zoomIn     = "Zoom In"
    case zoomOut    = "Zoom Out"
    case zoomBlur   = "Zoom Blur"
    case flip       = "Flip"
    case twist      = "Twist"
    case blur       = "Blur In"
    case none       = "Cut"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var sfSymbol: String {
        switch self {
        case .fade:       return "circle.lefthalf.filled"
        case .slideLeft:  return "arrow.left"
        case .slideRight: return "arrow.right"
        case .slideUp:    return "arrow.up"
        case .slideDown:  return "arrow.down"
        case .zoomIn:     return "magnifyingglass.circle.fill"
        case .zoomOut:    return "minus.magnifyingglass"
        case .zoomBlur:   return "circle.hexagongrid.fill"
        case .flip:       return "rotate.3d"
        case .twist:      return "arrow.triangle.2.circlepath"
        case .blur:       return "aqi.medium"
        case .none:       return "scissors"
        }
    }
}

// MARK: - BackgroundService

@MainActor
final class BackgroundService: ObservableObject {

    /// Weak ref to the single `@StateObject` instance, set in `init()` —
    /// lets `AccountService.pullSync` push freshly-pulled per-user gallery
    /// settings into the live, already-running instance (see `loadSettings()`),
    /// rather than only writing to `UserDefaults` where they'd sit unused
    /// until the next app launch.
    static weak var shared: BackgroundService?

    // MARK: Published State

    @Published var isEnabled: Bool = false {
        didSet { saveSettings() }
    }
    @Published var images: [UIImage] = []
    /// `PhotosPickerItem.itemIdentifier` (or a generated UUID placeholder for
    /// entries with no known source identifier — cloud-restored images,
    /// orphaned-disk-scan recovery) for each entry in `images`, same order/
    /// count, always kept in lockstep. Lets the picker refuse to re-add a
    /// photo the user has already uploaded to the gallery — see
    /// `isAssetAlreadyAdded(_:)`.
    @Published private(set) var imageAssetIDs: [String] = []
    /// Original GIF file bytes for any animated entry in `images` (nil for
    /// everything else) — same order/count as `images`. `UIImage` has no
    /// lossless way to re-encode an animated image back to GIF bytes, so the
    /// raw data has to be carried alongside it from pick-time through to
    /// `saveImagesToDisk()`, which writes it straight to a `.gif` file instead
    /// of flattening to JPEG.
    private var imageGIFData: [Data?] = []
    /// Small (≤200px) previews for the management grid in
    /// `BackgroundSettingsView`, kept in lockstep with `images` via
    /// `rebuildThumbnails()`. Rendering that grid directly off `images`
    /// (full ~1280px downsamples, one per photo) is what made the gallery
    /// grind to a halt once a library grew past ~100 photos — every row
    /// forced SwiftUI to lay out and composite a full-size bitmap instead of
    /// a genuinely thumbnail-sized one. `images` itself is unchanged and
    /// still what the actual full-screen slideshow displays.
    @Published private(set) var thumbnails: [UIImage] = []
    @Published var currentIndex: Int = 0
    @Published var shuffleIntervalSeconds: Double = 30.0 {
        didSet {
            saveSettings()
            if isActive { startShuffling() }  // restart with new interval
        }
    }
    @Published var animation: BackgroundAnimation = .fade {
        didSet { saveSettings() }
    }
    @Published var opacity: Double = 0.35 {
        didSet { saveSettings() }
    }
    /// Gaussian blur radius applied to the background image, 0-40. Replaces
    /// the old on/off `isBlurred` toggle — the Help screen has always
    /// described this as "a blur slider" with a 20-40 range, but the control
    /// was actually a binary switch with a fixed radius of 16 (8 in the
    /// settings preview). `loadSettings()` migrates any previously-saved
    /// `isBlurred` bool into an equivalent radius (16 or 0) on first load.
    @Published var blurRadius: Double = 16.0 {
        didSet { saveSettings() }
    }

    /// When on, the current background image slowly zooms/pans while it's
    /// displayed (not just at the transition between images) — a subtle
    /// "Ken Burns" ambient motion. Ignored when Reduce Motion is on (see
    /// `GalleryBackgroundView`).
    @Published var kenBurnsEnabled: Bool = false {
        didSet { saveSettings() }
    }

    /// True when the shuffle timer is running. Stored property so iOS backgrounding
    /// doesn't silently invalidate it without us knowing.
    @Published private(set) var isActive: Bool = false

    // MARK: Private

    private var shuffleTimer: Timer?
    // Tracks every timer added to the RunLoop so none are orphaned on rapid addImages calls.
    private var allTimers: [Timer] = []
    private var foregroundObserver: NSObjectProtocol?

    /// Debounce task for automatic cloud gallery backup — mirrors
    /// `AccountService.schedulePush`'s 2-second debounce so rapid successive
    /// `addImages`/`removeImage`/`clearAll` calls (e.g. picking 20 photos at
    /// once) only trigger one upload pass.
    private var cloudSyncTask: Task<Void, Never>?

    /// Set once per app launch the first time a cloud gallery restore has been
    /// attempted, so `loadSettings()` (which can run more than once, e.g. after
    /// `willEnterForegroundNotification`) doesn't repeatedly hit the network.
    private var didAttemptCloudRestore = false

    /// True only while `loadSettings()` is assigning the persisted values back
    /// into the published properties. Each of those assignments fires the
    /// property's `didSet → saveSettings()`, and `saveSettings()` writes EVERY
    /// field — so without this guard the first assignment (e.g. `isEnabled`)
    /// would persist the not-yet-loaded `animation`/`opacity` defaults
    /// (`.fade`/`0.35`) back over the user's real saved values before they
    /// were even read, which is exactly why the Appearance slider and
    /// Transition Animation selection failed to persist across launches.
    private var isLoadingSettings = false

    // MARK: Init — register for foreground notification

    init() {
        Self.shared = self
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, !self.images.isEmpty else { return }
                if !self.isActive { self.startShuffling() }
            }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    // MARK: Interval Presets

    static let intervalPresets: [(label: String, seconds: Double)] = [
        ("5 sec", 5), ("10 sec", 10), ("15 sec", 15), ("30 sec", 30),
        ("1 min", 60), ("2 min", 120), ("5 min", 300)
    ]

    // MARK: UserDefaults Keys

    private enum Keys {
        static let isEnabled             = "bgService.isEnabled"
        static let shuffleInterval       = "bgService.shuffleInterval"
        static let animation             = "bgService.animation"
        static let opacity               = "bgService.opacity"
        static let blurRadius            = "bgService.blurRadius"
        static let kenBurnsEnabled       = "bgService.kenBurnsEnabled"
        /// Legacy on/off blur switch — read once during migration in `loadSettings()`.
        static let isBlurredLegacy       = "bgService.isBlurred"
        static let imageFilenames        = "bg_image_filenames_v1"  // [String] of filenames
        static let imageAssetIDs         = "bg_image_asset_ids_v1"  // [String], same order as imageFilenames
        /// How many of `images` (counting from the front, matching upload
        /// order) are confirmed uploaded to the cloud gallery — see
        /// `scheduleCloudGallerySync`/`resumeIncompleteCloudGallerySyncIfNeeded`.
        static let cloudSyncedCount      = "bg_gallery_cloud_synced_count"
    }

    // MARK: Disk Storage Directory

    private var imageStorageDir: URL {
        // Documents is effectively always available on iOS, but crashing the whole
        // app over a missing directory for a background-image feature is too harsh —
        // fall back to the (always-available) temp directory and degrade gracefully.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("BackgroundImages", isDirectory: true)
    }

    // MARK: Image Management

    /// Memory-efficient downsample straight from encoded image data via ImageIO —
    /// produces a thumbnail at most `maxDimension` px on its long edge WITHOUT
    /// ever decoding the full-resolution image. Background images are shown
    /// full-screen and blurred, so a modest size is plenty; this keeps a large
    /// gallery (up to 150 photos) from decoding hundreds of MB of full-res
    /// bitmaps and spiking memory. Returns nil if the data isn't a decodable image.
    static func downsampledImage(from data: Data, maxDimension: CGFloat = 1280) -> UIImage? {
        ImageDownsampler.downsampled(from: data, maxPixelSize: maxDimension)
    }

    /// Below this on its longer edge, `image` is almost certainly not a real
    /// photo — a genuine camera/screenshot/library photo is essentially never
    /// this small even heavily downsampled, but a system-generated fallback
    /// (e.g. iOS handing back a small placeholder bitmap for a Photos asset
    /// the app doesn't actually have access to read, rather than failing the
    /// load outright) typically is. Reported symptom this guards against: the
    /// gallery background "stuck" showing what looks like a large system
    /// icon full-screen — `.scaleAspectFill` stretches whatever's at the
    /// current index to fill the screen, so a single tiny placeholder bitmap
    /// blown up that way reads exactly like an oversized icon. Checked at
    /// every point an image enters `images` (a fresh Photos pick, a cloud
    /// restore, and loading from disk) so an already-corrupted on-disk
    /// gallery self-heals on next load instead of needing the user to
    /// manually clear and re-add everything.
    private static let minPlausiblePhotoDimension: CGFloat = 200

    static func isPlausiblePhoto(_ image: UIImage) -> Bool {
        max(image.size.width, image.size.height) >= minPlausiblePhotoDimension
    }

    /// Regenerates `thumbnails` from `images` — a cheap in-memory resize
    /// (`ImageDownsampler.downscaled`, no re-decode) of already-loaded
    /// bitmaps, not a file read. Called after every mutation of `images`;
    /// safe to call on a large gallery since a resize is ~milliseconds per
    /// photo and this only runs on add/remove/load, never per-render.
    private func rebuildThumbnails() {
        thumbnails = images.map { ImageDownsampler.downscaled($0, maxPixelSize: 200) }
    }

    /// - Parameters:
    ///   - assetIDs: `PhotosPickerItem.itemIdentifier` per new image, same
    ///     order/count as `newImages`. A `nil` entry (or omitting this
    ///     parameter entirely) gets a generated UUID placeholder instead — it
    ///     just means that particular image can never be recognized as a
    ///     duplicate of a future pick, not an error.
    ///   - gifDataList: original GIF file bytes per new image (nil for
    ///     non-animated entries), same order/count as `newImages`. See
    ///     `imageGIFData`'s doc comment.
    func addImages(_ newImages: [UIImage], assetIDs: [String?]? = nil, gifDataList: [Data?]? = nil) {
        let ids = (assetIDs ?? Array(repeating: nil, count: newImages.count)).map { $0 ?? UUID().uuidString }
        let gifs = gifDataList ?? Array(repeating: nil, count: newImages.count)

        // Filter out anything implausibly small for a real photo HERE — the
        // one choke point every caller (the Photos picker, a cloud-gallery
        // restore) funnels through — rather than trusting each call site to
        // have already checked. See `isPlausiblePhoto`'s doc comment.
        var filteredImages: [UIImage] = []
        var filteredIDs: [String] = []
        var filteredGIFs: [Data?] = []
        for (index, image) in newImages.enumerated() {
            guard Self.isPlausiblePhoto(image) else {
                appWarn("addImages: rejecting image at index \(index) — implausibly small for a real photo (\(image.size))", category: "background")
                continue
            }
            filteredImages.append(image)
            filteredIDs.append(ids[index])
            filteredGIFs.append(gifs[index])
        }
        guard !filteredImages.isEmpty else { return }

        images.append(contentsOf: filteredImages)
        imageAssetIDs.append(contentsOf: filteredIDs)
        imageGIFData.append(contentsOf: filteredGIFs)
        rebuildThumbnails()
        saveImagesToDisk()
        if !isEnabled {
            isEnabled = true
            saveSettings()
        }
        // Always (re)start to ensure a single clean timer — startShuffling() kills all orphans first.
        currentIndex = 0
        startShuffling()
        objectWillChange.send()
        appLog("addImages: gallery ready (images=\(images.count), active=\(isActive))", category: "background")
        scheduleCloudGallerySync(newImages: filteredImages)
    }

    /// True if `assetIdentifier` (a `PhotosPickerItem.itemIdentifier`) matches
    /// a photo already in the gallery — lets the picker silently skip
    /// re-adding a photo the user has already uploaded instead of creating a
    /// duplicate entry.
    func isAssetAlreadyAdded(_ assetIdentifier: String) -> Bool {
        imageAssetIDs.contains(assetIdentifier)
    }

    func removeImage(at index: Int) {
        guard images.indices.contains(index) else { return }
        images.remove(at: index)
        if thumbnails.indices.contains(index) {
            thumbnails.remove(at: index)
        }
        if imageAssetIDs.indices.contains(index) {
            imageAssetIDs.remove(at: index)
        }
        if imageGIFData.indices.contains(index) {
            imageGIFData.remove(at: index)
        }
        if images.isEmpty {
            currentIndex = 0
            stopShuffling()
        } else if currentIndex >= images.count {
            currentIndex = images.count - 1
        }
        saveImagesToDisk()
        scheduleCloudGallerySync()
    }

    func clearAll() {
        images.removeAll()
        thumbnails.removeAll()
        imageAssetIDs.removeAll()
        imageGIFData.removeAll()
        currentIndex = 0
        saveImagesToDisk()
        scheduleCloudGallerySync()
    }

    // MARK: Cloud Gallery Backup (automatic, all logged-in users, no opt-in)

    /// Schedules an automatic cloud backup of the gallery 2 seconds after the
    /// last image-list mutation. When `newImages` is non-nil, only those new
    /// images are uploaded (existing cloud copies are left alone); otherwise
    /// (removal/clear) the full local gallery is re-synced — any cloud image
    /// no longer present locally is deleted so cloud and device stay in sync.
    private func scheduleCloudGallerySync(newImages: [UIImage]? = nil) {
        guard AccountService.shared?.isLoggedIn == true,
              let streaming = StreamingService.shared else { return }

        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard let self, !Task.isCancelled,
                  let token = AccountService.shared?.token, !token.isEmpty
            else { return }

            if let newImages, !newImages.isEmpty {
                // Upload-only path: just push the newly-added images.
                //
                // Backgrounding (or closing) the app mid-loop used to kill this
                // plain Task outright — a regular URLSession data task gets no
                // extra run time once the app suspends, so the backup silently
                // stopped partway with no record of how far it got, and never
                // resumed. Two fixes: (1) request a background execution
                // window via beginBackgroundTask, giving iOS a real chance to
                // let the in-flight upload(s) finish even if the user leaves
                // the app immediately after adding photos; (2) persist how
                // many images are confirmed synced after each success, so if
                // the app IS killed before finishing, the next launch's
                // resumeIncompleteCloudGallerySyncIfNeeded() picks up where it
                // left off instead of silently staying incomplete forever.
                let bgTaskID = await MainActor.run {
                    UIApplication.shared.beginBackgroundTask(withName: "GalleryCloudUpload")
                }
                defer {
                    if bgTaskID != .invalid {
                        Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTaskID) }
                    }
                }

                let startOrder = self.images.count - newImages.count
                for (offset, image) in newImages.enumerated() {
                    guard !Task.isCancelled else { return }
                    let order = startOrder + offset
                    do {
                        _ = try await streaming.uploadGalleryImage(image, token: token, displayOrder: order)
                        let syncedCount = order + 1
                        if syncedCount > UserDefaults.standard.integer(forKey: Keys.cloudSyncedCount) {
                            UserDefaults.standard.set(syncedCount, forKey: Keys.cloudSyncedCount)
                        }
                    } catch {
                        appWarn("BackgroundService: cloud gallery upload failed: \(error.localizedDescription)", category: "background")
                        // Stop rather than skip ahead — a later image "succeeding"
                        // while an earlier one failed would let cloudSyncedCount
                        // advance past a real gap. resumeIncompleteCloudGallerySyncIfNeeded
                        // retries from the first unconfirmed image on next launch/foreground.
                        return
                    }
                }
                appLog("BackgroundService: auto-uploaded \(newImages.count) new gallery image(s) to cloud", category: "background")
                return
            }

            // Removal/clear path: reconcile the cloud gallery to match the local
            // image count by deleting the trailing cloud entries beyond what's
            // left locally. We don't have a stable per-image cloud ID locally,
            // so this is a best-effort prune rather than a precise diff.
            do {
                let cloud = try await streaming.fetchGalleryImages(token: token)
                let excess = cloud.count - self.images.count
                if excess > 0 {
                    let toDelete = cloud.sorted { $0.displayOrder > $1.displayOrder }.prefix(excess)
                    for image in toDelete {
                        guard !Task.isCancelled else { return }
                        try? await streaming.deleteGalleryImage(id: image.id, token: token)
                    }
                    appLog("BackgroundService: pruned \(excess) cloud gallery image(s) after local removal", category: "background")
                }
                // Cloud is now reconciled to exactly `images.count` entries —
                // clamp the resume marker so it can't stay stuck pointing past
                // the (now smaller) local gallery.
                UserDefaults.standard.set(self.images.count, forKey: Keys.cloudSyncedCount)
            } catch {
                appWarn("BackgroundService: cloud gallery reconcile failed: \(error.localizedDescription)", category: "background")
            }
        }
    }

    /// Resumes an upload backup that got cut short (e.g. the app was closed
    /// or suspended mid-loop) — compares the persisted "confirmed synced"
    /// count against how many images actually exist locally now, and
    /// re-uploads whatever tail is missing. Call on launch/foreground; no-ops
    /// when nothing's pending (the common case).
    func resumeIncompleteCloudGallerySyncIfNeeded() {
        guard AccountService.shared?.isLoggedIn == true else { return }
        let syncedCount = UserDefaults.standard.integer(forKey: Keys.cloudSyncedCount)
        guard syncedCount < images.count else { return }
        let pending = Array(images[syncedCount...])
        appLog("resumeIncompleteCloudGallerySyncIfNeeded: resuming \(pending.count) unsynced gallery image(s)", category: "background")
        scheduleCloudGallerySync(newImages: pending)
    }

    /// Called on first login after a fresh install/reinstall (when the local
    /// gallery is empty but the user has cloud-backed-up images) to redownload
    /// and repopulate the local gallery automatically — no opt-in toggle.
    /// Safe to call repeatedly; only does work once per app launch and only
    /// when there are no local images yet (so it never clobbers images the
    /// user has already picked on this device).
    func restoreGalleryFromCloudIfNeeded() {
        guard !didAttemptCloudRestore else { return }
        guard images.isEmpty else {
            didAttemptCloudRestore = true
            return
        }
        guard AccountService.shared?.isLoggedIn == true,
              let token = AccountService.shared?.token, !token.isEmpty,
              let streaming = StreamingService.shared
        else { return }

        didAttemptCloudRestore = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let cloud = try await streaming.fetchGalleryImages(token: token)
                guard !cloud.isEmpty else { return }
                var restored: [UIImage] = []
                for entry in cloud.sorted(by: { $0.displayOrder < $1.displayOrder }) {
                    if let img = await streaming.fetchGalleryImageData(entry, token: token), Self.isPlausiblePhoto(img) {
                        restored.append(img)
                    }
                }
                guard !restored.isEmpty else { return }
                // Append directly to `images`/disk rather than via `addImages` —
                // avoids re-triggering an upload of the images we just downloaded.
                // Cloud gallery entries carry no local asset identifier or raw
                // GIF bytes (the cloud backup path always stores/returns a
                // decoded static image) — placeholder UUIDs and nil GIF data
                // keep the parallel arrays in lockstep with `images`.
                self.images = restored
                self.imageAssetIDs = (0..<restored.count).map { _ in UUID().uuidString }
                self.imageGIFData = Array(repeating: nil, count: restored.count)
                self.rebuildThumbnails()
                self.saveImagesToDisk()
                if !self.isEnabled {
                    self.isEnabled = true
                    self.saveSettings()
                }
                self.currentIndex = 0
                self.startShuffling()
                // These images came FROM the cloud, so they're already synced
                // — without this, resumeIncompleteCloudGallerySyncIfNeeded()
                // would see 0 confirmed-synced against a non-empty local
                // gallery on the next launch and re-upload every one of them
                // right back to the cloud as duplicates.
                UserDefaults.standard.set(restored.count, forKey: Keys.cloudSyncedCount)
                appLog("restoreGalleryFromCloudIfNeeded: restored \(restored.count) gallery image(s) from cloud", category: "background")
                ToastCenter.shared.show("Restored \(restored.count) background image\(restored.count == 1 ? "" : "s") from your account", category: .success, icon: "icloud.and.arrow.down")
            } catch {
                appWarn("restoreGalleryFromCloudIfNeeded: \(error.localizedDescription)", category: "background")
            }
        }
    }

    // MARK: Disk Persistence

    private func loadImagesFromDisk() {
        let defaults = UserDefaults.standard
        guard let filenames = defaults.stringArray(forKey: Keys.imageFilenames) else {
            appLog("loadImagesFromDisk: no saved filenames — scanning disk for orphaned images", category: "background")
            rebuildManifestFromDisk()
            return
        }
        let fm = FileManager.default
        var loaded: [UIImage] = []
        var loadedGIFData: [Data?] = []
        for name in filenames {
            let path = imageStorageDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: path) else {
                appWarn("loadImagesFromDisk: failed to load \(name)", category: "background")
                continue
            }
            // Cap each decoded GIF frame to 1280px, same as static photos —
            // GIF bytes saved to disk before this cap existed can still be
            // full photo-library resolution across every frame, and decoding
            // those at full size on every launch is what let a large gallery
            // balloon into hundreds of MB of in-memory bitmaps.
            if (name as NSString).pathExtension.lowercased() == "gif", let animated = UIImage.gifImage(data: data, maxDimension: 1280) {
                guard Self.isPlausiblePhoto(animated) else {
                    appWarn("loadImagesFromDisk: skipping \(name) — implausibly small for a real photo (\(animated.size))", category: "background")
                    continue
                }
                loaded.append(animated)
                loadedGIFData.append(data)
            } else if let img = UIImage(data: data) {
                guard Self.isPlausiblePhoto(img) else {
                    appWarn("loadImagesFromDisk: skipping \(name) — implausibly small for a real photo (\(img.size))", category: "background")
                    continue
                }
                loaded.append(img)
                loadedGIFData.append(nil)
            } else {
                appWarn("loadImagesFromDisk: failed to decode \(name)", category: "background")
            }
        }
        images = loaded
        imageGIFData = loadedGIFData
        // Asset IDs are persisted separately from filenames (same intended
        // order) — padded with fresh UUIDs if short, e.g. upgrading from a
        // version of the app that predates this feature, so indices can never
        // drift out of lockstep with `images`.
        var savedIDs = defaults.stringArray(forKey: Keys.imageAssetIDs) ?? []
        while savedIDs.count < loaded.count { savedIDs.append(UUID().uuidString) }
        imageAssetIDs = Array(savedIDs.prefix(loaded.count))
        rebuildThumbnails()
        appLog("loadImagesFromDisk: loaded \(loaded.count)/\(filenames.count) images", category: "background")
        if isEnabled && !images.isEmpty {
            startShuffling()
        }
    }

    /// Scans imageStorageDir for JPEG/PNG/GIF files and rebuilds the UserDefaults
    /// manifest. Called after a reinstall when the manifest key is missing but
    /// image files still exist. No asset identifiers survive this path (there's
    /// nothing on disk to recover them from) — each recovered image gets a
    /// fresh UUID placeholder, same as any other "unknown source" entry.
    private func rebuildManifestFromDisk() {
        // Records "there is nothing here" as a real answer.
        //
        // Every early return below used to leave the manifest key UNSET, which is
        // the same state that sent us here in the first place — so `loadImagesFromDisk`
        // took the "no saved filenames" branch again on the very next call and
        // re-scanned the disk, forever. For the common case of a user with no
        // custom backgrounds (the directory does not even exist) that repeated on
        // every single invocation: 53 disk scans in eight hours, each one
        // rediscovering the same nothing.
        //
        // Writing an empty manifest distinguishes "we looked and there is nothing"
        // from "we have never looked", which is the distinction the guard in
        // `loadImagesFromDisk` is actually trying to make. Any real image added
        // later goes through `saveImagesToDisk`, which rewrites this key anyway.
        func recordEmptyManifest() {
            UserDefaults.standard.set([String](), forKey: Keys.imageFilenames)
            UserDefaults.standard.set([String](), forKey: Keys.imageAssetIDs)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: imageStorageDir.path) else {
            recordEmptyManifest()
            return
        }
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "gif"]
        let files = (try? fm.contentsOfDirectory(atPath: imageStorageDir.path)) ?? []
        let imageFiles = files
            .filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        guard !imageFiles.isEmpty else {
            recordEmptyManifest()
            return
        }
        var loaded: [UIImage] = []
        var loadedGIFData: [Data?] = []
        for name in imageFiles {
            let path = imageStorageDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: path) else { continue }
            if (name as NSString).pathExtension.lowercased() == "gif", let animated = UIImage.gifImage(data: data, maxDimension: 1280) {
                guard Self.isPlausiblePhoto(animated) else { continue }
                loaded.append(animated)
                loadedGIFData.append(data)
            } else if let img = UIImage(data: data) {
                guard Self.isPlausiblePhoto(img) else { continue }
                loaded.append(img)
                loadedGIFData.append(nil)
            }
        }
        guard !loaded.isEmpty else {
            // Files existed but none decoded into a usable image — still a
            // conclusive "nothing to restore", so do not keep rediscovering it.
            recordEmptyManifest()
            return
        }
        images = loaded
        imageGIFData = loadedGIFData
        imageAssetIDs = (0..<loaded.count).map { _ in UUID().uuidString }
        rebuildThumbnails()
        UserDefaults.standard.set(imageFiles, forKey: Keys.imageFilenames)
        UserDefaults.standard.set(imageAssetIDs, forKey: Keys.imageAssetIDs)
        appLog("rebuildManifestFromDisk: restored \(loaded.count) image(s) from disk", category: "background")
        if isEnabled { startShuffling() }
    }

    private func saveImagesToDisk() {
        let fm = FileManager.default
        try? fm.createDirectory(at: imageStorageDir, withIntermediateDirectories: true)

        // Capture existing files before writing new ones so we can clean up orphans
        let existing = (try? fm.contentsOfDirectory(atPath: imageStorageDir.path)) ?? []

        var filenames: [String] = []
        for (i, img) in images.enumerated() {
            let rawGIF = imageGIFData.indices.contains(i) ? imageGIFData[i] : nil
            // Animated entries write their ORIGINAL GIF bytes rather than
            // `img.jpegData(...)` — re-encoding an animated UIImage to JPEG
            // only captures its first frame, which would silently un-animate
            // the background on the very next app launch.
            let ext = rawGIF != nil ? "gif" : "jpg"
            let name = "bg_\(i)_\(Int(Date().timeIntervalSince1970)).\(ext)"
            let path = imageStorageDir.appendingPathComponent(name)
            if let rawGIF {
                try? rawGIF.write(to: path)
                filenames.append(name)
            } else if let data = img.jpegData(compressionQuality: 0.8) {
                try? data.write(to: path)
                filenames.append(name)
            }
        }

        // Remove old images not in the new set
        for file in existing {
            if !filenames.contains(file) {
                try? fm.removeItem(at: imageStorageDir.appendingPathComponent(file))
            }
        }

        UserDefaults.standard.set(filenames, forKey: Keys.imageFilenames)
        UserDefaults.standard.set(Array(imageAssetIDs.prefix(filenames.count)), forKey: Keys.imageAssetIDs)
    }

    // MARK: Shuffle Control

    func startShuffling() {
        // Kill every tracked timer — prevents orphaned timers from rapid addImages calls.
        allTimers.forEach { $0.invalidate() }
        allTimers.removeAll()
        shuffleTimer = nil

        guard isEnabled, !images.isEmpty else {
            isActive = false
            appLog("startShuffling: skipped (enabled=\(isEnabled) images=\(images.count))", category: "background")
            return
        }
        let timer = Timer(timeInterval: shuffleIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        shuffleTimer = timer
        allTimers = [timer]
        isActive = true
        appLog("startShuffling: timer started interval=\(shuffleIntervalSeconds)s images=\(images.count)", category: "background")
    }

    func stopShuffling() {
        allTimers.forEach { $0.invalidate() }
        allTimers.removeAll()
        shuffleTimer = nil
        isActive = false
        appLog("stopShuffling: timer stopped", category: "background")
    }

    func nextImage() {
        advance()
        // Reset the timer so the next automatic advance starts fresh
        if isEnabled { startShuffling() }
    }

    // MARK: Private Advance

    private func advance() {
        guard !images.isEmpty else { return }
        let next = (currentIndex + 1) % images.count
        appLog("advance: index → \(next)/\(images.count)", category: "background")
        // Cap the crossfade so it always finishes before the next shuffle
        // tick fires — at the fastest preset (5s) an 8s transition would
        // still be mid-animation when the next `advance()` lands, causing
        // the incoming image to jump/cut instead of completing its fade.
        let duration = min(8.0, shuffleIntervalSeconds * 0.6)
        withAnimation(.easeInOut(duration: duration)) {
            currentIndex = next
        }
    }

    // MARK: Persistence

    func saveSettings() {
        // Suppressed while loadSettings() is populating the published
        // properties — see `isLoadingSettings`. Without this, the didSet on an
        // already-loaded property would call saveSettings() and write the
        // remaining (not-yet-loaded) properties' default values back over the
        // user's persisted ones.
        guard !isLoadingSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: Keys.isEnabled)
        defaults.set(shuffleIntervalSeconds, forKey: Keys.shuffleInterval)
        defaults.set(animation.rawValue, forKey: Keys.animation)
        defaults.set(opacity, forKey: Keys.opacity)
        defaults.set(blurRadius, forKey: Keys.blurRadius)
        defaults.set(kenBurnsEnabled, forKey: Keys.kenBurnsEnabled)
    }

    func loadSettings() {
        let defaults = UserDefaults.standard

        // Guard against each property's didSet re-persisting partially-loaded
        // state (see `isLoadingSettings`); one explicit saveSettings() runs at
        // the end so any first-load migration (e.g. the legacy blur toggle) is
        // still written back.
        isLoadingSettings = true

        // isEnabled — default false when key absent
        isEnabled = defaults.bool(forKey: Keys.isEnabled)

        if let interval = defaults.object(forKey: Keys.shuffleInterval) as? Double {
            shuffleIntervalSeconds = interval
        }

        if let rawAnim = defaults.string(forKey: Keys.animation),
           let anim = BackgroundAnimation(rawValue: rawAnim) {
            animation = anim
        }

        if let savedOpacity = defaults.object(forKey: Keys.opacity) as? Double {
            opacity = savedOpacity
        }

        kenBurnsEnabled = defaults.bool(forKey: Keys.kenBurnsEnabled)

        if let savedRadius = defaults.object(forKey: Keys.blurRadius) as? Double {
            blurRadius = savedRadius
        } else if let legacyBlur = defaults.object(forKey: Keys.isBlurredLegacy) as? Bool {
            // One-time migration from the old on/off toggle.
            blurRadius = legacyBlur ? 16.0 : 0.0
            defaults.removeObject(forKey: Keys.isBlurredLegacy)
            defaults.set(blurRadius, forKey: Keys.blurRadius)
        }

        isLoadingSettings = false

        // Load persisted images from disk; this also starts shuffling if enabled
        loadImagesFromDisk()

        // If enabled was saved as true but no images could be loaded, disable.
        if isEnabled, images.isEmpty {
            isEnabled = false
        }
        appLog("loadSettings: enabled=\(isEnabled) images=\(images.count) interval=\(shuffleIntervalSeconds)s active=\(isActive)", category: "background")

        // Automatic cloud restore for returning users on a fresh install: if no
        // local gallery images exist but the account has cloud-backed-up ones,
        // redownload them. No-ops for logged-out users or users with local images.
        restoreGalleryFromCloudIfNeeded()

        // Resume any backup that was interrupted last session (app closed/
        // suspended mid-upload) — no-ops when the gallery was already fully
        // synced. Runs after restore so a fresh-install restore doesn't
        // immediately "resume" uploading the images it just downloaded.
        resumeIncompleteCloudGallerySyncIfNeeded()
    }
}
