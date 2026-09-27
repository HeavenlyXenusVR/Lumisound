import Accelerate
import AVFoundation

/// Computes a real-time frequency spectrum from the live audio graph, for
/// the "Live Spectrum" Now Playing artwork style. Taps `mainMixerNode` (see
/// `AudioPlayerManager.startVisualizerTap`) rather than decoding/analyzing
/// anything separately, so it reacts to exactly what's actually audible
/// (effects, EQ, crossfade included) — entirely on-device, no server.
///
/// Also the app's one real "audio listener/analyzer" — Auto EQ
/// (`AudioPlayerManager.applyAutoEQIfNeeded`) and Smart Auto Crossfade
/// (`AudioPlayerManager.smartFadeDuration`), both in
/// `AudioPlayerManager+Crossfade.swift`, read `bassLevel`/`midLevel`/
/// `trebleLevel`/`overallLevel` off the SAME per-buffer FFT pass this
/// already runs for the visualizer, rather than each standing up its own
/// tap/analysis (only one tap can be installed on `mainMixerNode` bus 0 at a
/// time, and a second FFT pass over the same audio would just be wasted CPU).
@MainActor
final class AudioVisualizerService: ObservableObject {
    static let shared = AudioVisualizerService()

    /// Identifies why a caller wants analysis running — the underlying tap
    /// stays installed as long as at least one reason is active. A `Set`
    /// (rather than a plain ref count) is what makes `start(for:)`/
    /// `stop(for:)` idempotent per-reason: the existing Live Spectrum view
    /// already calls `start()`/`stop()` from both `.onAppear`/`.onDisappear`
    /// AND `.onChange(of: isPlaying)` without them being strictly paired 1:1
    /// (SwiftUI view identity churn, multiple views bound to the same
    /// `isPlaying`, etc.) — a plain counter would drift out of sync and
    /// leave the tap either stuck on or stuck off. Inserting/removing the
    /// same reason twice is always safe.
    enum AnalysisReason: Hashable {
        case liveSpectrumUI
        case autoEQ
        case smartCrossfade
        case musicHaptics
        case galleryReactiveBackground
    }
    private var activeReasons: Set<AnalysisReason> = []

    static let barCount = 24

    /// Smoothed per-bar magnitude, 0...1.
    @Published private(set) var magnitudes: [Float] = Array(repeating: 0, count: barCount)

    /// Coarse smoothed band energy, 0...1 (relative/self-referential, not
    /// calibrated to an absolute loudness reference) — derived from the same
    /// `fftMagnitudes` the 24-bar spectrum uses, just summed into 3 broad
    /// ranges instead of 24 log-spaced ones. Bass ~20-250Hz, mid
    /// ~250Hz-4kHz, treble ~4-16kHz.
    @Published private(set) var bassLevel: Float = 0
    @Published private(set) var midLevel: Float = 0
    @Published private(set) var trebleLevel: Float = 0
    /// Smoothed overall level across the full spectrum, 0...1.
    @Published private(set) var overallLevel: Float = 0

    private let fftSize = 2048
    private let log2n: vDSP_Length = 11 // 2^11 == 2048
    private let fftSetup: FFTSetup?

    private init() {
        fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Requests analysis for `reason`. Safe to call repeatedly for the same
    /// reason (idempotent), and safe to call from multiple independent
    /// reasons at once — the tap stays installed as long as any reason is
    /// active. Back-compat no-arg overload defaults to the original Live
    /// Spectrum UI call sites' meaning.
    func start(for reason: AnalysisReason = .liveSpectrumUI) {
        let wasInactive = activeReasons.isEmpty
        activeReasons.insert(reason)
        appLog("AudioVisualizerService: start(for: \(reason)) — active reasons now \(activeReasons)", category: "audio")
        guard wasInactive else { return }
        guard AudioPlayerManager.shared != nil else {
            appWarn("AudioVisualizerService: start(for: \(reason)) requested but AudioPlayerManager.shared is nil — tap not installed", category: "audio")
            return
        }
        appLog("AudioVisualizerService: installing analyzer tap on the main mixer", category: "audio")
        lastLevelLogTime = .distantPast
        AudioPlayerManager.shared?.startVisualizerTap { [weak self] buffer in
            self?.process(buffer: buffer)
        }
    }

    /// Releases `reason`'s interest in analysis. The underlying tap only
    /// actually stops once no reason remains active. Safe to call for a
    /// reason that was never started (a harmless no-op).
    func stop(for reason: AnalysisReason = .liveSpectrumUI) {
        activeReasons.remove(reason)
        appLog("AudioVisualizerService: stop(for: \(reason)) — active reasons now \(activeReasons)", category: "audio")
        guard activeReasons.isEmpty else { return }
        appLog("AudioVisualizerService: removing analyzer tap — no reasons remain active", category: "audio")
        AudioPlayerManager.shared?.stopVisualizerTap()
        magnitudes = Array(repeating: 0, count: Self.barCount)
        bassLevel = 0
        midLevel = 0
        trebleLevel = 0
        overallLevel = 0
    }

    /// Throttle for the periodic band-level trace below — `applySmoothed`
    /// runs on every audio buffer (tens of times/sec), so logging every call
    /// would flood the log; this proves the analyzer is actually receiving
    /// and processing live audio (not stuck at 0) without the spam.
    private var lastLevelLogTime: Date = .distantPast
    private let levelLogInterval: TimeInterval = 3.0

    /// Runs on the audio render thread (the tap's callback), not the main
    /// thread — `nonisolated` so it can execute there directly instead of
    /// needing to hop actors just to start; only the final publish step
    /// hops back to the main actor.
    nonisolated private func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let available = Int(buffer.frameLength)
        guard available > 0 else { return }

        let n = min(available, fftSize)
        var real = [Float](repeating: 0, count: fftSize)
        var imag = [Float](repeating: 0, count: fftSize)
        let samples = channelData[0]
        for i in 0..<n { real[i] = samples[i] }

        guard let fftSetup else { return }
        var bars = [Float](repeating: 0, count: Self.barCount)
        var bandLevels: (bass: Float, mid: Float, treble: Float, overall: Float) = (0, 0, 0, 0)
        let sampleRate = Float(buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 44100)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                let halfSize = fftSize / 2
                var fftMagnitudes = [Float](repeating: 0, count: halfSize)
                fftMagnitudes.withUnsafeMutableBufferPointer { magPtr in
                    guard let magBase = magPtr.baseAddress else { return }
                    vDSP_zvmags(&split, 1, magBase, 1, vDSP_Length(halfSize))
                }

                // Logarithmically-spaced bins — otherwise almost all musical
                // energy (bass/mid) collapses into the first couple of bars
                // and everything above that reads as flat silence.
                for bar in 0..<Self.barCount {
                    let lowFrac = pow(Double(bar) / Double(Self.barCount), 2)
                    let highFrac = pow(Double(bar + 1) / Double(Self.barCount), 2)
                    let lowBin = max(1, Int(lowFrac * Double(halfSize)))
                    let highBin = max(lowBin + 1, min(halfSize, Int(highFrac * Double(halfSize))))
                    guard lowBin < highBin else { continue }
                    let slice = fftMagnitudes[lowBin..<highBin]
                    let avg = slice.reduce(0, +) / Float(slice.count)
                    bars[bar] = min(1, max(0, log10(avg + 1) / 4))
                }

                // Coarse bass/mid/treble energy — same magnitude array, summed
                // over actual frequency ranges (Hz -> bin index) rather than
                // the log-spaced display bins above, since Auto EQ/Smart
                // Crossfade care about real frequency bands, not display bars.
                let binHz = sampleRate / Float(fftSize)
                func bandAverage(_ lowHz: Float, _ highHz: Float) -> Float {
                    let lowBin = max(1, Int(lowHz / binHz))
                    let highBin = max(lowBin + 1, min(halfSize, Int(highHz / binHz)))
                    guard lowBin < highBin else { return 0 }
                    let slice = fftMagnitudes[lowBin..<highBin]
                    return slice.reduce(0, +) / Float(slice.count)
                }
                func normalize(_ v: Float) -> Float { min(1, max(0, log10(v + 1) / 4)) }

                let bass = normalize(bandAverage(20, 250))
                let mid = normalize(bandAverage(250, 4000))
                let treble = normalize(bandAverage(4000, min(16000, sampleRate / 2)))
                let overallAvg = fftMagnitudes.reduce(0, +) / Float(max(1, fftMagnitudes.count))
                bandLevels = (bass, mid, treble, normalize(overallAvg))
            }
        }

        Task { @MainActor [weak self] in
            self?.applySmoothed(bars, bands: bandLevels)
        }
    }

    private func applySmoothed(_ new: [Float], bands: (bass: Float, mid: Float, treble: Float, overall: Float)) {
        if new.count == magnitudes.count {
            for i in 0..<magnitudes.count {
                magnitudes[i] = magnitudes[i] * 0.55 + new[i] * 0.45
            }
        }
        let smoothing: Float = 0.7
        bassLevel = bassLevel * smoothing + bands.bass * (1 - smoothing)
        midLevel = midLevel * smoothing + bands.mid * (1 - smoothing)
        trebleLevel = trebleLevel * smoothing + bands.treble * (1 - smoothing)
        overallLevel = overallLevel * smoothing + bands.overall * (1 - smoothing)

        // Proof-of-life trace: confirms the analyzer is actually reading
        // live signal (levels tracking what's playing) rather than silently
        // stuck at 0 for every active reason — throttled so it's readable
        // instead of one line per buffer.
        //
        // `localOnly`: this fires every few seconds for as long as anything is
        // playing, which made it the single largest source of rows in the shared
        // server log table — 78,601 in one retention window, about 14% of
        // everything, for a line whose only use is watching one device analyse one
        // track. It stays in the console and in bug-report context, where it is
        // actually read, and no longer travels.
        let now = Date()
        if now.timeIntervalSince(lastLevelLogTime) >= levelLogInterval {
            lastLevelLogTime = now
            appLog(
                String(
                    format: "AudioVisualizerService: levels bass=%.2f mid=%.2f treble=%.2f overall=%.2f (reasons: %@)",
                    bassLevel, midLevel, trebleLevel, overallLevel, "\(activeReasons)"
                ),
                category: "audio",
                localOnly: true
            )
        }
    }
}
