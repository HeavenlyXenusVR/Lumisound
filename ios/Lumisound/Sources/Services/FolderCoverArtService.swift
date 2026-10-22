import Foundation
import UIKit
import CryptoKit

// MARK: - FolderCoverArtService
//
// Per-folder custom cover art for LocalFolderDetailView — lets the user pick
// a photo to represent a local folder instead of always falling back to the
// first song's embedded artwork (or a generic folder glyph). Deliberately
// device-local only, no bridge/server involvement: stored under
// Documents/FolderCoverArt, keyed by a stable SHA-256 of the folder's
// standardized path so lookups survive relaunches without a network
// round-trip. A per-device cover choice is a reasonable thing to NOT sync —
// unlike library content, there's no "source of truth" to reconcile across
// devices, and the folder's underlying files (which the cover represents)
// aren't shared across devices either.
@MainActor
final class FolderCoverArtService: ObservableObject {
    static let shared = FolderCoverArtService()

    /// Bumped on every `setCover`/`removeCover` — this class had no
    /// `@Published` property at all before, so changing a cover from
    /// `LocalFolderDetailView` never notified anything, including the
    /// Folders grid's own cells. `onAppear` only fires when a cell is
    /// first created; SwiftUI doesn't tear down and recreate a grid's
    /// already-mounted cells just because the user navigated to a detail
    /// screen and back, so a cell that was on screen before the change
    /// kept showing whatever it had cached from ITS OWN first appearance
    /// — "the folder icon only changes inside the detail screen, not in
    /// the folders section itself." `FolderGridCell` observes this to know
    /// when to re-check.
    @Published private(set) var changeCount: Int = 0

    /// In-memory cache of loaded covers, keyed by the same digest used for
    /// the on-disk filename — avoids re-reading from disk on every header
    /// render for a folder already visited this launch.
    private var cache: [String: UIImage] = [:]

    /// Keys confirmed to have no custom cover on disk — the common case
    /// (most folders never get one). Without this, every folder with no
    /// custom cover paid a `Data(contentsOf:)` miss (a real disk stat/open
    /// attempt, on the main actor — this type is `@MainActor`) on every
    /// single `cover(for:)` call: once per `FolderGridCell.onAppear` as it
    /// scrolls into view, and again every time a folder's detail screen
    /// opens. Small in isolation, but it compounds with the other folder-
    /// nav costs (see LocalFolderDetailView/LibraryHubView) scrolling a grid
    /// or reopening the same folder repeatedly.
    private var noCoverKeys: Set<String> = []

    private init() {}

    private var storageDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("FolderCoverArt", isDirectory: true)
    }

    /// Stable, filesystem-safe key for `folderURL` — a raw path can't be used
    /// directly as a filename (slashes, length limits), and `String.hashValue`
    /// isn't guaranteed stable across launches (Swift randomizes its seed), so
    /// this hashes a path with SHA-256 instead.
    ///
    /// Hashes the Documents-RELATIVE path (`ScanCacheService
    /// .documentsRelativePath`), not the folder's absolute path — the app's
    /// sandbox container UUID (the `/var/mobile/Containers/Data/Application/
    /// <UUID>/...` prefix of every absolute path) changes across reinstalls
    /// and can also be reassigned by iOS after a device restore/migration
    /// even without a reinstall. Hashing the absolute path meant every
    /// stored cover's lookup key silently stopped matching its folder the
    /// next time that happened — the cover file was still sitting on disk,
    /// just unreachable under its old digest, so custom folder covers
    /// appeared to randomly vanish. Falls back to the absolute path only
    /// for a folder genuinely outside Documents (shouldn't happen for a
    /// local library folder, but keeps this from ever returning empty).
    private func key(for folderURL: URL) -> String {
        let path = ScanCacheService.documentsRelativePath(for: folderURL) ?? folderURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for folderURL: URL) -> URL {
        storageDir.appendingPathComponent(key(for: folderURL)).appendingPathExtension("jpg")
    }

    /// Returns the cached/persisted cover for `folderURL`, if one was ever
    /// set — `nil` means "use the default" (first song's artwork / folder
    /// glyph), the same fallback LocalFolderDetailView already had.
    func cover(for folderURL: URL) async -> UIImage? {
        let k = key(for: folderURL)
        if let cached = cache[k] { return cached }
        if noCoverKeys.contains(k) { return nil }
        // Off the main actor — every FolderGridCell/folder-detail header calls
        // this in `onAppear`/`.task(id:)` on first appearance, and for any
        // folder that genuinely has a custom cover (the `noCoverKeys` miss
        // cache only helps the no-cover case), that's a real disk read +
        // JPEG decode. A fast fling through a never-before-seen stretch of
        // the Folders grid fires a burst of these in quick succession —
        // exactly the "holds static, then jumps" scroll-stutter pattern seen
        // in a field screen recording, since this used to block the main
        // actor directly inside onAppear's layout pass.
        let path = fileURL(for: folderURL)
        let image: UIImage? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: path) else { return nil }
            return UIImage(data: data)
        }.value
        guard let image else {
            noCoverKeys.insert(k)
            return nil
        }
        cache[k] = image
        return image
    }

    /// Saves `image` as the cover for `folderURL`, downsampled to a fixed
    /// max size first — this is only ever displayed at up to the 256x256
    /// header size, so there's no reason to keep a full-resolution
    /// photo-library asset on disk (same rationale as BackgroundService's
    /// thumbnail downsampling).
    func setCover(_ image: UIImage, for folderURL: URL) {
        let downsized = ImageDownsampler.downscaled(image, maxPixelSize: 512)
        guard let data = downsized.jpegData(compressionQuality: 0.85) else { return }
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: folderURL), options: .atomic)
            let k = key(for: folderURL)
            cache[k] = downsized
            noCoverKeys.remove(k)
            changeCount += 1
            appLog("FolderCoverArtService: set custom cover for \"\(folderURL.lastPathComponent)\"", category: "library")
        } catch {
            appWarn("FolderCoverArtService: failed to save cover for \"\(folderURL.lastPathComponent)\": \(error.localizedDescription)", category: "library")
        }
    }

    /// Removes the custom cover for `folderURL`, reverting the header back
    /// to the default (first song's artwork / folder glyph).
    func removeCover(for folderURL: URL) {
        let k = key(for: folderURL)
        cache.removeValue(forKey: k)
        try? FileManager.default.removeItem(at: fileURL(for: folderURL))
        changeCount += 1
        appLog("FolderCoverArtService: removed custom cover for \"\(folderURL.lastPathComponent)\"", category: "library")
    }
}
