import Foundation

// MARK: - TVAutoCrossfade
//
// Chooses a crossfade length per transition instead of using one fixed number,
// ported from the iPhone app's `smartFadeDuration`.
//
// The tvOS player already crossfades, but always for exactly six seconds — the
// same overlap between two quiet ambient pieces and between two loud remixes,
// and the same whether the outgoing track ends on a long tail or stops dead.
// A fixed overlap is wrong in both directions: too long and two busy passages
// smear together, too short and a natural fade is cut off.
//
// What it decides from, in order of how much each is trusted:
//
//   1. **Tempo**, when known — the fade is snapped to a whole number of beats so
//      it begins and ends on a downbeat rather than part-way through a bar. This
//      is the piece that makes a transition sound deliberate rather than merely
//      gradual.
//   2. **How the outgoing track is actually ending** — measured from its own
//      audio rather than assumed. A track still at full energy near its end
//      reads as an abrupt cut, so the overlap tightens; one already fading out
//      has room for a longer blend.
//   3. **Track length** — a ninety-second track cannot give up six seconds to a
//      fade without losing a meaningful part of itself.
//
// The energy nudge is deliberately one-directional on iOS (never longer than the
// base) because its level reading cannot distinguish real silence from "the
// analyser has not settled yet". tvOS has no live analyser at all, so the same
// question is answered a different way here: the outgoing track's tail is
// measured directly, which is unambiguous, and can therefore lengthen as well as
// shorten.
enum TVAutoCrossfade {
    /// What the setting means when Auto is off.
    static let baseDuration: TimeInterval = 6

    /// Never overlap more than this share of the shorter track.
    private static let maxTrackFraction: Double = 0.12
    private static let minDuration: TimeInterval = 1.5
    private static let maxDuration: TimeInterval = 12

    /// Picks the overlap for a transition.
    ///
    /// - Parameters:
    ///   - outgoingDuration: length of the track ending, 0 if unknown.
    ///   - incomingDuration: length of the track starting, 0 if unknown.
    ///   - bpm: tempo of the incoming track, nil if unknown.
    ///   - tailLevel: RMS of the outgoing track's final seconds, 0...1, nil if
    ///     it could not be measured.
    static func duration(outgoingDuration: TimeInterval,
                         incomingDuration: TimeInterval,
                         bpm: Double?,
                         tailLevel: Double?) -> TimeInterval {
        var fade = baseDuration

        // 1. Energy. A loud ending wants a tight overlap; a track already
        //    trailing off can afford a longer one.
        if let tailLevel {
            let level = min(1, max(0, tailLevel))
            // 1.35x when the track has essentially faded out, 0.7x at full tilt.
            fade *= 1.35 - level * 0.65
        }

        // 2. Beat-snap, so the fade starts and ends on a downbeat. Clamped to
        //    ±50% of where we started, so an unusually slow or fast track cannot
        //    turn a short crossfade into a long one on tempo alone.
        if let bpm, bpm > 0 {
            let beat = 60.0 / bpm
            let beats = max(1, (fade / beat).rounded())
            fade = min(max(beats * beat, baseDuration * 0.5), baseDuration * 1.5)
        }

        // 3. Never eat a meaningful share of a short track. Checked against BOTH
        //    sides: a six-second fade out of a ninety-second track is as wrong as
        //    a six-second fade into one.
        for length in [outgoingDuration, incomingDuration] where length > 0 {
            fade = min(fade, length * maxTrackFraction)
        }

        return min(max(fade, minDuration), maxDuration)
    }
}

// MARK: - TVTailLevel

import AVFoundation

/// Measures how loud a track's final seconds actually are.
///
/// This is the signal iOS cannot get cleanly: its live analyser reports `0` both
/// for genuine silence and for "not settled yet", so the nudge there has to be
/// one-directional to stay safe. Reading the file's tail directly has no such
/// ambiguity — a quiet answer means the track really is quiet there — so the
/// result can lengthen a fade as well as shorten it.
///
/// Cached per URL: a crossfade happens at the end of every track, and decoding
/// the same tail twice for a repeat play is wasted work.
enum TVTailLevel {
    private static var cache: [String: Double] = [:]
    /// How much of the ending to look at.
    private static let windowSeconds: Double = 8

    /// Returns 0...1, or nil when the file cannot be decoded (Opus via
    /// AVAssetReader, most often) — in which case the caller simply skips the
    /// energy term rather than guessing a value.
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
