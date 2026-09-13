import AVFoundation
import Foundation

// MARK: - Mood Bucket

enum MoodBucket: String, CaseIterable {
    case energetic = "Energetic"
    case chill     = "Chill"
    case focus     = "Focus"
    case sleep     = "Sleep"
}

// MARK: - MoodPlaylistService

@MainActor
final class MoodPlaylistService: ObservableObject {

    // MARK: Published

    @Published private(set) var energeticSongs: [Song] = []
    @Published private(set) var chillSongs: [Song]     = []
    @Published private(set) var focusSongs: [Song]     = []
    @Published private(set) var sleepSongs: [Song]     = []
    @Published private(set) var isAnalyzing: Bool      = false

    // MARK: Weak reference to library

    weak var libraryManager: LibraryManager?

    /// Mirrors `AccountService.shared`/`LibraryManager.shared` — gives
    /// non-view code (e.g. `DiagnosticsSnapshotService`) a way to reach the
    /// live instance without needing it threaded through as a parameter.
    static weak var shared: MoodPlaylistService?

    init() {
        Self.shared = self
    }

    // MARK: - Public API

    /// Re-analyzes using the current set of songs from `libraryManager`.
    func reanalyze() {
        guard let library = libraryManager else { return }
        Task { await analyze(songs: library.allSongs) }
    }

    /// Analyzes the provided song list and distributes songs into mood buckets.
    /// Runs at background priority so the main thread is never blocked.
    func analyze(songs: [Song]) async {
        guard !songs.isEmpty else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        // Run expensive AVAsset metadata reads at background priority.
        let library = libraryManager
        let classified: [(Song, MoodBucket)] = await Task.detached(priority: .background) {
            var results: [(Song, MoodBucket)] = []
            for song in songs {
                let mood = await Self.classify(song: song, library: library)
                results.append((song, mood))
            }
            return results
        }.value

        var energetic: [Song] = []
        var chill:     [Song] = []
        var focus:     [Song] = []
        var sleep:     [Song] = []

        for (song, mood) in classified {
            switch mood {
            case .energetic: energetic.append(song)
            case .chill:     chill.append(song)
            case .focus:     focus.append(song)
            case .sleep:     sleep.append(song)
            }
        }

        // Publish results on MainActor.
        self.energeticSongs = energetic
        self.chillSongs     = chill
        self.focusSongs     = focus
        self.sleepSongs     = sleep
    }

    // MARK: - Classification Logic (nonisolated so it can run off main actor)

    private static func classify(song: Song, library: LibraryManager?) async -> MoodBucket {
        // 1. Already-analyzed tempo (from `BPMAnalyzerService`, via the library),
        //    then an embedded BPM/TBPM tag, then on-device analysis as a final
        //    fallback — so tracks with neither a tag nor a prior analysis still
        //    get a tempo-based bucket instead of falling through to genre/title
        //    keyword matching.
        var bpm = song.bpm
        if bpm == nil, let url = song.url {
            bpm = await fetchBPM(from: url)
        }
        if bpm == nil {
            bpm = await library?.bpm(for: song)
        }
        if let bpm {
            switch bpm {
            case ..<60:   return .sleep
            case 60..<90: return .chill
            case 90..<120: return .focus
            default:      return .energetic    // >= 120
            }
        }

        // 2. Genre-based classification.
        if !song.genre.isEmpty {
            let genre = song.genre.lowercased()
            if matchesAny(genre, keywords: ["rock", "metal", "hip", "hop", "dance", "punk", "rave",
                                             "drum", "edm", "electronic", "pop", "funk", "trap"]) {
                return .energetic
            }
            if matchesAny(genre, keywords: ["classical", "jazz", "ambient", "lo-fi", "lofi",
                                             "chill", "soul", "bossa", "blues", "easy"]) {
                return .chill
            }
            if matchesAny(genre, keywords: ["instrumental", "study", "focus", "piano",
                                             "orchestral", "soundtrack", "cinematic"]) {
                return .focus
            }
            if matchesAny(genre, keywords: ["soft", "acoustic", "sleep", "lullaby",
                                             "new age", "meditation", "relaxation"]) {
                return .sleep
            }
        }

        // 3. Title keyword heuristics.
        let title = song.displayName.lowercased()
        let artist = song.artistName.lowercased()
        let combined = "\(title) \(artist)"

        if matchesAny(combined, keywords: ["sleep", "rain", "lofi", "lo-fi", "night", "lullaby",
                                            "relax", "calm", "peaceful", "dreamy", "drift"]) {
            return .sleep
        }
        if matchesAny(combined, keywords: ["workout", "pump", "energy", "hype", "run", "rage",
                                            "beast", "grind", "power", "fire", "turbo"]) {
            return .energetic
        }
        if matchesAny(combined, keywords: ["study", "focus", "work", "deep", "flow",
                                            "concentration", "think"]) {
            return .focus
        }
        if matchesAny(combined, keywords: ["chill", "vibe", "sunset", "breeze", "lazy",
                                            "morning", "coffee", "mellow", "soft"]) {
            return .chill
        }

        // 4. Duration heuristic: very short → energetic, very long → focus/chill.
        if song.duration > 0 {
            if song.duration < 120 { return .energetic }   // < 2 min — likely a short pop/hype track
            if song.duration > 480 { return .focus }       // > 8 min — likely a long ambient/instrumental
        }

        // 5. Default fallback: round-robin across buckets based on ID to ensure variety.
        let index = abs(song.id.hashValue) % 4
        return MoodBucket.allCases[index]
    }

    /// Returns true if `text` contains any of the given keywords.
    private static func matchesAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    /// Reads the BPM (beats per minute) from a local file's AVAsset metadata.
    /// Returns nil if unavailable or the file cannot be read.
    private static func fetchBPM(from url: URL) async -> Double? {
        // Only attempt for local file URLs to avoid slow network requests.
        guard url.isFileURL else { return nil }

        // A `.lms`-locked url's on-disk bytes are XOR-masked and unreadable
        // by AVURLAsset until unlocked -- without this, mood classification's
        // BPM tier silently never fired for locked tracks (fell through to
        // the keyword/duration heuristics instead).
        let readableURL = LumisoundExclusiveExtensionService.playableURL(for: url)
        return await Task.detached(priority: .background) {
            let asset = AVURLAsset(url: readableURL)
            guard let metadata = try? await asset.load(.commonMetadata) else { return nil as Double? }

            for item in metadata {
                guard let key = item.commonKey?.rawValue.lowercased() else { continue }
                // Look for BPM tag across common metadata key names.
                guard key.contains("bpm") || key.contains("tempo") else { continue }
                if let str = try? await item.load(.stringValue),
                   let bpm = Double(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return bpm
                }
                if let num = try? await item.load(.numberValue) {
                    return num.doubleValue
                }
            }

            // Also check format-specific metadata for ID3 TBPM or similar.
            if let allMeta = try? await asset.load(.metadata) {
                for item in allMeta {
                    let identifier = item.identifier?.rawValue.lowercased() ?? ""
                    guard identifier.contains("bpm") || identifier.contains("tempo") else { continue }
                    if let str = try? await item.load(.stringValue),
                       let bpm = Double(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        return bpm
                    }
                }
            }

            return nil as Double?
        }.value
    }
}
