import Foundation

// MARK: - TransitionProfile
//
// How a track ends and how one begins, measured server-side by
// `locked_media.transition_profile` and delivered with the track.
//
// Measured there rather than here for two reasons. The server can read inside a
// locked (`.lms`) file, and it can analyse a track this device has not
// downloaded yet. More importantly, one implementation feeding both apps is the
// only way iOS and tvOS reach the same decision about the same pair of tracks —
// two separate heuristics, however carefully written, drift apart.
struct TransitionProfile: Equatable, Hashable, Codable {
    /// Dead air on the end of the file, in seconds.
    var trailingSilence: Double = 0
    /// dB change per second across the last of the real music. Negative is
    /// fading away.
    var outroSlopeDB: Double = 0
    /// The music stops abruptly rather than tapering.
    var outroColdStop: Bool = false
    /// How far in the track actually starts.
    var introLeadIn: Double = 0
    /// 0...1. How fast it reaches full level once it has started — a downbeat is
    /// there immediately, a fade-in climbs.
    var introOnsetHardness: Double = 0
}

// MARK: - SmartCrossfade
//
// Chooses when a crossfade starts and how long it runs.
//
// Kept byte-for-byte equivalent to tvOS's `TVAutoCrossfade` — same inputs, same
// constants, same order of operations. The two platforms share the measurements
// already; sharing the rules too is what stops the same transition sounding
// different depending on which screen it is playing from.
//
// The change that matters most is that a fade no longer starts a fixed distance
// from the END OF THE FILE. It starts a fixed distance from the end of the
// MUSIC. Measured across a real cloud library, 8 tracks in 25 carry more than
// 1.5s of trailing dead air and one had thirty-eight seconds — so a fade
// triggered at `duration - 6s` was often partly, occasionally entirely, the next
// track fading up over nothing. That is invisible to anything that looks at
// levels, because silence and a quiet fade-out measure identically at the end.
enum SmartCrossfade {
    private static let maxTrackFraction: Double = 0.12
    private static let minDuration: TimeInterval = 1.5
    private static let maxDuration: TimeInterval = 12

    struct Plan: Equatable {
        /// How long the overlap runs.
        var duration: TimeInterval
        /// How far before the END OF THE FILE the fade should begin. Larger than
        /// `duration` whenever the outgoing track has dead air on the end.
        var startBefore: TimeInterval
        /// Why, for the log — a transition that sounds wrong is otherwise very
        /// hard to reason about after the fact.
        var reason: String
    }

    static func plan(base: TimeInterval,
                     outgoingDuration: TimeInterval,
                     incomingDuration: TimeInterval,
                     outgoing: TransitionProfile?,
                     incoming: TransitionProfile?,
                     outgoingBPM: Double?,
                     incomingBPM: Double?,
                     measuredLevel: Double?) -> Plan {
        var fade = base
        var reasons: [String] = []

        // 1. Outro shape. Preferred over any measured level: the profile can
        //    separate a stop from a sustain, and a level cannot — both are loud
        //    right up to the last moment.
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
        } else if let measuredLevel {
            // Fallback for a track the server has not profiled yet. One-
            // directional, because this reading is 0 both for real silence and
            // for "the analyser has not settled", and those cannot be told apart.
            let level = min(1, max(0, measuredLevel))
            fade *= 1.0 - level * 0.3
            reasons.append("level")
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

        // 3. Tempo compatibility, BEFORE the beat-snap — snapping to a beat the
        //    other track is fighting does not help anything.
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
            fade = min(max(beats * beat, base * 0.5), base * 1.5)
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
