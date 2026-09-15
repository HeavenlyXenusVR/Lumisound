import AVFoundation
import Foundation

// MARK: - TVAudioSettings
//
// The playback preferences the settings screen exposes, persisted in
// UserDefaults and read by `TVPlayerModel`.
//
// Aria is deliberately absent. She has no stored flag here and no row on the
// settings screen — there is nothing to read, so there is no disabled path to
// maintain or accidentally leave broken.

@MainActor
final class TVAudioSettings: ObservableObject {
    static let shared = TVAudioSettings()

    private enum Key {
        static let skipSilentIntros = "tv.audio.skipSilentIntros"
        static let spatialize = "tv.audio.allowSpatialization"
        static let crossfade = "tv.player.crossfadeEnabled"
        static let autoCrossfade = "tv.audio.autoCrossfade"
        static let djTransitions = "tv.aria.djTransitions"
        static let gridColumns = "tv.library.gridColumns"
    }

    /// Trims a track's leading silence on start — see `TVSilenceTrim`.
    @Published var skipSilentIntros: Bool {
        didSet { UserDefaults.standard.set(skipSilentIntros, forKey: Key.skipSilentIntros) }
    }

    /// Whether the system may spatialise stereo music.
    ///
    /// This is the setting most likely behind "tvOS doesn't sound as clear as
    /// iOS". An Apple TV with spatial audio on will upmix plain stereo into a
    /// virtualised surround field, which smears the stereo image and is commonly
    /// described exactly that way — less clear, less direct — while the identical
    /// file on a phone plays untouched. It is a real, audible difference that
    /// has nothing to do with the bytes being streamed, and iOS never had it
    /// because headphone/phone playback doesn't take that path.
    ///
    /// Default OFF: music should reach the room as it was mastered, and anyone
    /// who wants the effect can switch it back on.
    @Published var allowSpatialization: Bool {
        didSet {
            UserDefaults.standard.set(allowSpatialization, forKey: Key.spatialize)
            TVRemoteLogger.log(category: "audio", event: "spatialization_changed",
                               detail: ["allowed": allowSpatialization])
        }
    }

    @Published var crossfadeEnabled: Bool {
        didSet { UserDefaults.standard.set(crossfadeEnabled, forKey: Key.crossfade) }
    }

    /// Picks the crossfade length per transition rather than using a fixed six
    /// seconds — see `TVAutoCrossfade`. Only has an effect while `crossfadeEnabled`.
    @Published var autoCrossfade: Bool {
        didSet { UserDefaults.standard.set(autoCrossfade, forKey: Key.autoCrossfade) }
    }

    /// Aria's spoken handover line between tracks. This is a presentation
    /// preference, not an Aria switch — she still picks, still reasons, still
    /// runs. It only controls whether the line is shown.
    @Published var djTransitions: Bool {
        didSet { UserDefaults.standard.set(djTransitions, forKey: Key.djTransitions) }
    }

    /// Cards per row in the library grids. 2 / 3 / 4.
    @Published var gridColumns: Int {
        didSet { UserDefaults.standard.set(gridColumns, forKey: Key.gridColumns) }
    }

    private init() {
        let d = UserDefaults.standard
        // `object(forKey:)` rather than `bool(forKey:)` for the two that default
        // to true — `bool` returns false for an absent key, which would silently
        // ship them off on a fresh install.
        skipSilentIntros = (d.object(forKey: Key.skipSilentIntros) as? Bool) ?? true
        allowSpatialization = (d.object(forKey: Key.spatialize) as? Bool) ?? false
        crossfadeEnabled = d.bool(forKey: Key.crossfade)
        autoCrossfade = (d.object(forKey: Key.autoCrossfade) as? Bool) ?? true
        djTransitions = (d.object(forKey: Key.djTransitions) as? Bool) ?? true
        gridColumns = (d.object(forKey: Key.gridColumns) as? Int) ?? 3
    }
}

// MARK: - TVSilenceTrim
//
// Leading-silence detection, ported from iOS's `SilenceTrimAnalyzer` with the
// threshold rule corrected.
//
// The shipping iOS rule is:
//
//     threshold = min(peakWindowRMS * 0.02, 0.00316)
//
// `min` is the problem. 0.00316 is -50 dBFS, and `peakWindowRMS * 0.02` only
// drops below that when the track's loudest 20ms window is under an RMS of
// 0.158 — which does not happen for mastered music. So the relative term never
// applies and the threshold is a flat -50 dBFS for every real track: it finds
// digital silence and misses soft fade-ins entirely.
//
// Measured against 40 random tracks from a real cloud library, decoded with
// ffmpeg:
//
//   * the two rules agree on most tracks — the shipping one is not broken, and
//     this library genuinely has very little leading silence to find (longest
//     real intro ≈ 1.8s, median ≈ 0.3s);
//   * they differ on soft fade-ins, where a relative threshold finds the real
//     start and the flat floor does not — e.g. 0.16s → 0.69s and 0.22s → 0.83s;
//   * 15 of the 40 tracks produced a trim under 0.25s, which is inaudible and
//     risks clipping the attack of a quiet opening. Those are now discarded
//     rather than applied.
//
// So the honest summary is: a modest accuracy gain on fade-ins, and stopping the
// feature from doing pointless work on a third of tracks.
enum TVSilenceTrim {
    static let maxTrimSeconds: TimeInterval = 10
    /// Below this, trimming is inaudible and only risks cutting an attack.
    static let minTrimSeconds: TimeInterval = 0.25
    /// Window length for the RMS envelope. Raw samples cannot be used for an
    /// onset test — a waveform crosses zero every cycle, so any "is it loud now"
    /// check evaluated sample-by-sample flickers constantly.
    private static let windowSeconds = 0.02
    private static let sampleRate: Double = 11025

    /// Cached per track id, since analysis costs a decode of the first seconds.
    private static var cache: [String: TimeInterval] = [:]

    static func cachedTrim(for id: String) -> TimeInterval? { cache[id] }

    /// Analyses `url` and returns how much to skip, 0 when there is nothing
    /// worth skipping.
    static func analyze(url: URL, trackID: String) async -> TimeInterval {
        if let hit = cache[trackID] { return hit }
        let result = await Task.detached(priority: .utility) { () -> TimeInterval in
            guard let env = envelope(url: url), !env.isEmpty else { return 0 }
            guard let peak = env.max(), peak > 0 else { return 0 }

            // Relative to THIS track's own peak, with an absolute floor so a
            // very quiet recording cannot have a real intro eaten. `max`, not
            // `min`: silence is "below the more forgiving of the two bars",
            // which is what lets a soft fade-in register as a start at all.
            let threshold = Swift.max(peak * 0.01, 0.0015)

            var silentWindows = 0
            for value in env {
                if value < threshold { silentWindows += 1 } else { break }
            }
            let seconds = Double(silentWindows) * windowSeconds
            if seconds < minTrimSeconds { return 0 }
            return Swift.min(seconds, maxTrimSeconds)
        }.value
        cache[trackID] = result
        TVRemoteLogger.log(category: "audio", event: "silence_trim_analyzed",
                           detail: ["trackID": trackID,
                                    "trimSeconds": round(result * 100) / 100,
                                    "applied": result > 0])
        return result
    }

    /// Decodes the head of the file and reduces it to a 20ms RMS envelope.
    /// Uses AVAssetReader, so it works for anything AVFoundation can decode —
    /// and returns nil rather than guessing for anything it cannot (Opus), where
    /// the caller simply skips the feature for that track.
    private static func envelope(url: URL) -> [Double]? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: maxTrimSeconds + 5, preferredTimescale: 600))
        guard reader.startReading() else { return nil }

        let windowSize = Int(sampleRate * windowSeconds)
        var envelope: [Double] = []
        var pending: [Int16] = []
        pending.reserveCapacity(windowSize * 2)

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) { pending.append(samples[i]) }
            }
            while pending.count >= windowSize {
                var sum = 0.0
                for i in 0..<windowSize {
                    let v = Double(pending[i]) / Double(Int16.max)
                    sum += v * v
                }
                envelope.append((sum / Double(windowSize)).squareRoot())
                pending.removeFirst(windowSize)
            }
        }
        reader.cancelReading()
        return envelope
    }
}
