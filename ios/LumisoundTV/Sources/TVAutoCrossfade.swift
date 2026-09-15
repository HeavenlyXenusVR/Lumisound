import AVFoundation
import Foundation

// MARK: - TVTransitionProfile
//
// How a track ends and how one begins, measured server-side by
// `locked_media.transition_profile` and delivered with the track. Measured there
// rather than here because the server can read inside a locked (`.lms`) file and
// a client cannot analyse a track it has not downloaded yet — and because one
// implementation feeding both apps is the only way iOS and tvOS make the same
// decision about the same pair of tracks.
struct TVTransitionProfile: Equatable, Hashable {
    /// Dead air on the end of the file, in seconds.
    var trailingSilence: Double = 0
    /// dB change per second across the last of the real music. Negative is
    /// fading away.
    var outroSlopeDB: Double = 0
    /// The music stops abruptly rather than tapering.
    var outroColdStop: Bool = false
    /// How far in the incoming track actually starts.
    var introLeadIn: Double = 0
    /// 0...1. How much of the opening rise happens at once — a downbeat jumps,
    /// a fade-in climbs.
    var introOnsetHardness: Double = 0
}

// MARK: - TVAutoCrossfade
//
// Chooses when a crossfade starts and how long it runs.
//
// The first version used a fixed six seconds, then a tail-energy nudge and a
// beat-snap. This version adds the thing that turned out to matter most, which
// none of that could see:
//
// **Crossfades were routinely overlapping silence.** A fade triggered at
// `duration - 6s` assumes the track is still playing six seconds from the end.
// Measured across a real cloud library, 8 tracks in 25 have more than 1.5s of
// trailing dead air and one had thirty-eight seconds. Those transitions were not
// blending two tracks at all — the outgoing track had already finished and the
// incoming one was simply fading up over nothing, which is exactly why a
// crossfade can feel like an awkward gap instead of a join. Starting the fade
// before the dead air is the single biggest improvement here, and it is
// invisible to anything that only looks at levels, because silence and a quiet
// fade-out measure the same at the end.
//
// On top of that, four judgements the old version could not make:
//
//   1. **A cold stop is left alone.** A track that stops dead does so on
//      purpose; overlapping it smothers the ending. Level alone cannot tell a
//      hard stop from a sustained final chord — both are loud right up to the
//      end — so this needs the outro's SLOPE, not its volume.
//   2. **A fading outro is blended generously**, because there is already a
//      taper to blend into.
//   3. **A hard opening downbeat gets a shorter overlap** so the hit lands
//      clean; a track that fades in gets a longer one, since there is nothing
//      there to smear.
//   4. **Clashing tempos shorten the fade.** Two tracks at 80 and 140 overlapped
//      for six seconds are two conflicting pulses. Near-equal or double-time
//      tempos beat-match, so they keep the longer fade and get snapped to the
//      beat.
enum TVAutoCrossfade {
    static let baseDuration: TimeInterval = 6

    private static let maxTrackFraction: Double = 0.12
    private static let minDuration: TimeInterval = 1.5
    private static let maxDuration: TimeInterval = 12

    /// What a transition should do.
    struct Plan: Equatable {
        /// How long the overlap runs.
        var duration: TimeInterval
        /// How far before the END OF THE FILE the fade should begin. Larger than
        /// `duration` whenever the outgoing track has dead air on the end.
        var startBefore: TimeInterval
        /// Why, for telemetry — a transition that sounds wrong is otherwise very
        /// hard to reason about after the fact.
        var reason: String
    }

    static func plan(outgoingDuration: TimeInterval,
                     incomingDuration: TimeInterval,
                     outgoing: TVTransitionProfile?,
                     incoming: TVTransitionProfile?,
                     outgoingBPM: Double?,
                     incomingBPM: Double?,
                     tailLevel: Double?) -> Plan {
        var fade = baseDuration
        var reasons: [String] = []

        // 1. Outro shape. Preferred over the measured tail level when available:
        //    the profile distinguishes a stop from a sustain, which a level
        //    cannot.
        if let outgoing {
            if outgoing.outroColdStop {
                fade *= 0.35
                reasons.append("cold-stop")
            } else if outgoing.outroSlopeDB < -3 {
                fade *= 1.3
                reasons.append("fading-outro")
            } else if outgoing.outroSlopeDB < -1 {
                fade *= 1.1
                reasons.append("soft-outro")
            }
        } else if let tailLevel {
            // Fallback for a track with no profile yet.
            let level = min(1, max(0, tailLevel))
            fade *= 1.35 - level * 0.65
            reasons.append("tail-level")
        }

        // 2. Incoming shape.
        if let incoming {
            if incoming.introLeadIn > 1.0 {
                fade *= 1.25
                reasons.append("soft-intro")
            }
            if incoming.introOnsetHardness > 0.8 {
                fade *= 0.8
                reasons.append("hard-onset")
            }
        }

        // 3. Tempo compatibility, before the beat-snap — snapping to a beat the
        //    other track is fighting does not help.
        var beatSnap = true
        if let a = outgoingBPM, let b = incomingBPM, a > 0, b > 0 {
            let ratio = max(a, b) / min(a, b)
            let nearUnison = abs(ratio - 1) < 0.08
            let nearDouble = abs(ratio - 2) < 0.12
            if !(nearUnison || nearDouble) {
                fade *= 0.7
                beatSnap = false
                reasons.append("tempo-clash")
            }
        }

        if beatSnap, let bpm = incomingBPM, bpm > 0 {
            let beat = 60.0 / bpm
            let beats = max(1, (fade / beat).rounded())
            fade = min(max(beats * beat, baseDuration * 0.5), baseDuration * 1.5)
            reasons.append("beat-snapped")
        }

        // 4. Never eat a meaningful share of a short track, on either side.
        for length in [outgoingDuration, incomingDuration] where length > 0 {
            fade = min(fade, length * maxTrackFraction)
        }
        fade = min(max(fade, minDuration), maxDuration)

        // 5. Start before the dead air so the overlap lands on music.
        let silence = max(0, outgoing?.trailingSilence ?? 0)
        if silence > 0.3 { reasons.append(String(format: "skip-%.1fs-silence", silence)) }

        return Plan(duration: fade,
                    startBefore: fade + silence,
                    reason: reasons.isEmpty ? "default" : reasons.joined(separator: ","))
    }
}

// MARK: - TVTailLevel

/// Measures how loud a track's final seconds actually are.
///
/// Only used for tracks with no server profile yet — the profile supersedes it,
/// since a level cannot separate a cold stop from a sustained ending. Kept as a
/// fallback so a freshly-uploaded track still gets something better than a flat
/// six seconds while it waits to be analysed.
///
/// Cached per URL: a crossfade happens at the end of every track, and decoding
/// the same tail twice for a repeat play is wasted work.
enum TVTailLevel {
    private static var cache: [String: Double] = [:]
    private static let windowSeconds: Double = 8

    static func measure(url: URL, duration: TimeInterval) -> Double? {
        let key = url.absoluteString
        if let hit = cache[key] { return hit }
        guard duration > windowSeconds else { return nil }

        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: duration - windowSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: windowSeconds, preferredTimescale: 600)
        )
        guard reader.startReading() else { return nil }

        var sum = 0.0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) {
                    let v = Double(samples[i]) / Double(Int16.max)
                    sum += v * v
                    count += 1
                }
            }
        }
        reader.cancelReading()
        guard count > 0 else { return nil }

        let rms = (sum / Double(count)).squareRoot()
        // Scaled against a typical mastered RMS (~0.25) rather than full scale,
        // so a normally-loud ending reads as ~1 rather than as a quarter.
        let level = min(1, rms / 0.25)
        cache[key] = level
        return level
    }
}
