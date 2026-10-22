import Foundation

// MARK: - AudioEffectSpecialMode

/// Flat, Codable representation of a DSP oscillator or spatial mode.
/// Uses a tagged-union style struct so Swift can synthesise Codable automatically.
struct AudioEffectSpecialMode: Codable, Equatable {

    enum ModeType: String, Codable {
        case none, rotation, tremolo, vibrato
    }

    var type: ModeType = .none

    // Parameters for each mode — zero/default when mode is not active.
    var hz: Double      = 0          // rotation: cycles-per-second
    var freq: Double    = 0          // tremolo / vibrato: LFO frequency
    var depth: Float    = 0          // tremolo: depth [0–1]
    var pitchDepth: Double = 0       // vibrato: semitone deviation

    // MARK: Factory helpers (mirror the original enum cases)

    static let none = AudioEffectSpecialMode(type: .none)

    static func rotation(hz: Double) -> AudioEffectSpecialMode {
        AudioEffectSpecialMode(type: .rotation, hz: hz)
    }

    static func tremolo(freq: Double, depth: Float) -> AudioEffectSpecialMode {
        AudioEffectSpecialMode(type: .tremolo, freq: freq, depth: depth)
    }

    static func vibrato(freq: Double, depth: Double) -> AudioEffectSpecialMode {
        AudioEffectSpecialMode(type: .vibrato, freq: freq, pitchDepth: depth)
    }
}

// MARK: - AudioEffect

struct AudioEffect: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let icon: String           // SF Symbol name
    var eqBands: [Float]       // 10 values in dB (32Hz–16kHz)
    var eqEnabled: Bool        // whether EQ should be active
    var speed: Float           // 1.0 = normal playback speed
    var pitchSemitones: Float  // 0.0 = no pitch shift
    var specialMode: AudioEffectSpecialMode = .none
}

// MARK: - AudioEffectsService

enum AudioEffectsService {

    // MARK: All Presets

    /// All 25 effects — the previous 27 (Karaoke was pulled earlier still;
    /// center-channel cancellation never reliably worked across mixes)
    /// minus Bass Boost and 8D Audio, both now independent toggles
    /// (`AudioSettings.bassBoostEnabled`/`eightDAudioEnabled`) that can run
    /// alongside whichever effect from THIS list is picked, rather than one
    /// of the entries in it — the whole point being that they no longer
    /// have to compete with the rest of this list for the single "active
    /// effect" slot. `bassboost`/`eightD` stay defined as `AudioEffect`
    /// values below (Lua custom effects or other direct callers can still
    /// reference them by id), just no longer listed here.
    static let allEffects: [AudioEffect] = [
        none,
        nightcore,
        vaporwave,
        lofi,
        lowpass,
        soft,
        electronic,
        party,
        radio,
        cinema,
        pop,
        rock,
        classical,
        deep,
        anime,
        jazz,
        hiphop,
        acoustic,
        vocalBoost,
        doubletime,
        slowmo,
        pitchUp,
        pitchDown,
        tremolo,
        vibrato,
    ]

    // MARK: Preset Definitions
    //
    // Every EQ curve below is authored directly for this app's actual 10-band
    // AVAudioUnitEQ layout (32/64/125/250/500/1k/2k/4k/8k/16k Hz, shelf
    // filters at the two extremes — see AudioPlayerManager+SpatialAudio.swift
    // `configureEqualizer`), replacing the previous values, which were
    // mechanically converted from an unrelated 15-band system and only
    // approximated what they were named after.

    /// Flat — all defaults, no processing.
    static let none = AudioEffect(
        id: "none",
        name: "None",
        icon: "waveform",
        eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        eqEnabled: false,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Punchy sub/bass lift with a small compensating dip through the low-mids
    /// so it reads as "more bass", not "muddier".
    static let bassboost = AudioEffect(
        id: "bassboost",
        name: "Bass Boost",
        icon: "speaker.wave.3.fill",
        eqBands: [8.0, 6.5, 4.0, 1.0, -1.0, -1.5, -1.0, 0, 0, 0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Sped up + pitched up (unchanged), now paired with a bright, scooped
    /// EQ — the shimmery, energetic top end that's the actual Nightcore
    /// signature, not just a faster/higher-pitched flat mix.
    static let nightcore = AudioEffect(
        id: "nightcore",
        name: "Nightcore",
        icon: "moon.stars.fill",
        eqBands: [-1.0, -1.0, -0.5, 0, 0.5, 2.0, 3.5, 4.0, 3.0, 2.0],
        eqEnabled: true,
        speed: 1.25,
        pitchSemitones: 4.5
    )

    /// Slowed + pitched down (unchanged), now paired with a warm, rolled-off
    /// EQ — the washed-out "underwater cassette" tone the genre is named for.
    static let vaporwave = AudioEffect(
        id: "vaporwave",
        name: "Vaporwave",
        icon: "sunset.fill",
        eqBands: [3.0, 2.5, 1.5, 0.5, 0, -1.0, -2.0, -3.0, -4.5, -6.0],
        eqEnabled: true,
        speed: 0.8,
        pitchSemitones: -3.9
    )

    /// Dusty and mid-forward: a gentle low-mid lift for warmth, steep high
    /// rolloff for tape/vinyl character, plus the original mild speed/pitch dip.
    static let lofi = AudioEffect(
        id: "lofi",
        name: "Lo-Fi",
        icon: "radio.fill",
        eqBands: [1.0, 1.5, 1.5, 0.5, 0, -0.5, -1.5, -3.0, -6.0, -10.0],
        eqEnabled: true,
        speed: 0.94,
        pitchSemitones: -0.7
    )

    /// A pure filter effect (no genre coloring) — steep high-frequency rolloff only.
    static let lowpass = AudioEffect(
        id: "lowpass",
        name: "Low Pass",
        icon: "arrow.down.to.line",
        eqBands: [0, 0, 0, 0, 0, 0, 0, -2.0, -6.0, -11.5],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Gentle high-end rolloff — smoother, less fatiguing top end than Low Pass.
    static let soft = AudioEffect(
        id: "soft",
        name: "Soft",
        icon: "cloud.fill",
        eqBands: [0, 0, 0, 0, 0, 0, -0.5, -1.5, -3.5, -6.5],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Classic EDM "smiley" curve — boosted sub-bass and highs, scooped mids,
    /// for punch and sparkle without a muddy midrange.
    static let electronic = AudioEffect(
        id: "electronic",
        name: "Electronic",
        icon: "bolt.fill",
        eqBands: [3.0, 2.0, 0, -1.0, -1.5, -1.0, 1.0, 2.5, 3.5, 3.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// A more moderate smiley curve than Electronic — loud and fun without
    /// scooping the mids as hard, so vocals still cut through.
    static let party = AudioEffect(
        id: "party",
        name: "Party",
        icon: "party.popper.fill",
        eqBands: [4.0, 3.0, 1.0, 0, -1.0, -0.5, 0.5, 1.5, 2.5, 2.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Classic AM/FM band-limited sound — cut lows and highs, presence boost
    /// through the mids where speech/broadcast content actually lives.
    static let radio = AudioEffect(
        id: "radio",
        name: "Radio",
        icon: "antenna.radiowaves.left.and.right",
        eqBands: [-6.0, -4.0, -1.0, 1.0, 2.5, 3.0, 2.0, 0, -4.0, -8.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Cinematic and spacious — low-end rumble plus a touch of air up top,
    /// pairs well with the reverb already in the signal chain.
    static let cinema = AudioEffect(
        id: "cinema",
        name: "Cinema",
        icon: "film.fill",
        eqBands: [3.0, 2.0, 1.0, 0, 0, 0, 0.5, 1.0, 1.5, 1.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Bright and vocal-forward — modern pop mix character: a small presence
    /// boost, a light mid dip to avoid boxiness, and airy top end.
    static let pop = AudioEffect(
        id: "pop",
        name: "Pop",
        icon: "music.mic",
        eqBands: [0, 1.0, 1.5, 0.5, -1.0, -1.5, -0.5, 1.0, 2.5, 2.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// The classic rock "V" curve — boosted bass and highs with scooped
    /// low-mids, for driving guitars and crisp cymbals.
    static let rock = AudioEffect(
        id: "rock",
        name: "Rock",
        icon: "guitars.fill",
        eqBands: [4.0, 2.5, -1.0, -2.0, -1.0, 1.0, 2.5, 3.0, 2.0, 1.5],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Natural and accurate — classical listeners want fidelity, not
    /// coloring, so this is just a gentle warmth-and-air smile, nothing extreme.
    static let classical = AudioEffect(
        id: "classical",
        name: "Classical",
        icon: "pianokeys",
        eqBands: [1.0, 0.5, 0, 0, 0, 0, 0.5, 1.0, 1.5, 2.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Heavy sub-bass emphasis paired with a pitched-down mix — a deep-house
    /// low end without touching the mids/highs.
    static let deep = AudioEffect(
        id: "deep",
        name: "Deep",
        icon: "waveform.path",
        eqBands: [7.0, 5.5, 3.0, 0.5, -1.0, -1.5, -1.0, -0.5, 0, 0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: -3.9
    )

    /// Sped up + pitched up (unchanged), now paired with a bright,
    /// vocal-forward EQ — energetic opening-theme character.
    static let anime = AudioEffect(
        id: "anime",
        name: "Anime",
        icon: "star.fill",
        eqBands: [0, -0.5, -0.5, 0, 0.5, 1.5, 2.5, 3.5, 3.0, 2.5],
        eqEnabled: true,
        speed: 1.4,
        pitchSemitones: 7.0
    )

    /// Warm and smooth — present mids for brushed drums/upright bass/sax,
    /// gentle top-end air for cymbals, nothing scooped or aggressive.
    static let jazz = AudioEffect(
        id: "jazz",
        name: "Jazz",
        icon: "music.note",
        eqBands: [1.5, 1.0, 0.5, 0.5, 0, 0, 0.5, 1.0, 1.5, 1.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Heavy 808 sub-bass, a scooped low-mid to keep it from getting boxy,
    /// and crisp highs for hi-hats and vocal presence.
    static let hiphop = AudioEffect(
        id: "hiphop",
        name: "Hip-Hop",
        icon: "music.quarternote.3",
        eqBands: [6.0, 4.5, 1.0, -1.5, -1.0, 0, 1.0, 2.0, 2.5, 1.5],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Natural and warm — present low-mids for guitar body/vocal warmth,
    /// gentle top-end air for string detail, no scooping.
    static let acoustic = AudioEffect(
        id: "acoustic",
        name: "Acoustic",
        icon: "guitars",
        eqBands: [1.0, 1.0, 1.5, 1.0, 0.5, 0.5, 1.0, 1.0, 0.5, 1.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// Presence-focused — cuts low-end mud, boosts the 500Hz–4kHz range where
    /// speech intelligibility and lead vocals actually live. Works for
    /// podcasts/audiobooks as well as vocal-forward music.
    static let vocalBoost = AudioEffect(
        id: "vocal_boost",
        name: "Vocal Boost",
        icon: "person.wave.2.fill",
        eqBands: [-2.0, -1.5, -1.0, 0.5, 2.0, 3.0, 2.5, 1.0, 0, -1.0],
        eqEnabled: true,
        speed: 1.0,
        pitchSemitones: 0.0
    )

    /// doubletime: speed only — a pure utility transform, deliberately kept
    /// EQ-neutral (unlike the genre presets above) so it doesn't color the mix.
    static let doubletime = AudioEffect(
        id: "doubletime",
        name: "Double Time",
        icon: "forward.fill",
        eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        eqEnabled: false,
        speed: 2.0,
        pitchSemitones: 0.0
    )

    /// slowmo: speed only — a pure utility transform, deliberately kept
    /// EQ-neutral so it doesn't color the mix.
    static let slowmo = AudioEffect(
        id: "slowmo",
        name: "Slow Mo",
        icon: "backward.fill",
        eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        eqEnabled: false,
        speed: 0.5,
        pitchSemitones: 0.0
    )

    /// pitch_up: pitch only — a pure utility transform, deliberately kept
    /// EQ-neutral so it doesn't color the mix.
    static let pitchUp = AudioEffect(
        id: "pitch_up",
        name: "Pitch Up",
        icon: "arrow.up",
        eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        eqEnabled: false,
        speed: 1.0,
        pitchSemitones: 4.5
    )

    /// pitch_down: pitch only — a pure utility transform, deliberately kept
    /// EQ-neutral so it doesn't color the mix.
    static let pitchDown = AudioEffect(
        id: "pitch_down",
        name: "Pitch Down",
        icon: "arrow.down",
        eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        eqEnabled: false,
        speed: 1.0,
        pitchSemitones: -6.1
    )

    /// 8D Audio — oscillates stereo pan left/right at 0.18 Hz to simulate a rotating sound source
    /// (audible on any stereo output; see AudioPlayerManager.update8DRotation).
    static let eightD = AudioEffect(
        id: "8d",
        name: "8D Audio",
        icon: "rotate.3d",
        eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        eqEnabled: false,
        speed: 1.0,
        pitchSemitones: 0.0,
        specialMode: .rotation(hz: 0.18)
    )

    /// Tremolo — modulates volume with a 4 Hz sine LFO at 45 % depth.
    static let tremolo = AudioEffect(
        id: "tremolo",
        name: "Tremolo",
        icon: "waveform.path",
        eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        eqEnabled: false,
        speed: 1.0,
        pitchSemitones: 0.0,
        specialMode: .tremolo(freq: 4.0, depth: 0.45)
    )

    /// Vibrato — modulates pitch with a 4.5 Hz sine LFO at ±0.35 semitones.
    static let vibrato = AudioEffect(
        id: "vibrato",
        name: "Vibrato",
        icon: "waveform",
        eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        eqEnabled: false,
        speed: 1.0,
        pitchSemitones: 0.0,
        specialMode: .vibrato(freq: 4.5, depth: 0.35)
    )

    // MARK: Lookup

    /// Returns the effect matching the given id, or nil if not found.
    static func effect(id: String) -> AudioEffect? {
        allEffects.first { $0.id == id }
    }

    /// One-time migration for settings saved before Bass Boost and 8D Audio
    /// became independent toggles. A saved `activeEffectID` of "bassboost"
    /// or "8d" used to be the only way either was ever turned on; neither id
    /// is in `allEffects` any more, so silently leaving it as-is would look
    /// up nothing and leave both sounding off for anyone who had either
    /// selected. Carries it forward into the matching toggle instead — idempotent,
    /// safe to run on every load (a settings value already migrated, or one
    /// that never had either id, passes through unchanged).
    static func migratingLegacyExclusiveEffect(_ settings: AudioSettings) -> AudioSettings {
        var s = settings
        switch s.activeEffectID {
        case "bassboost":
            s.bassBoostEnabled = true
            s.activeEffectID = "none"
        case "8d":
            s.eightDAudioEnabled = true
            s.activeEffectID = "none"
        default:
            break
        }
        return s
    }

    // MARK: Apply

    /// Copies `settings`, applies the effect's speed/pitch (and EQ curve, only
    /// for EQ-defining effects), and stamps `activeEffectID`. The caller should
    /// assign the return value back to `AudioPlayerManager.audioSettings`.
    ///
    /// EQ, audio effects, and reverb are designed to LAYER: reverb is a separate
    /// node (untouched here), and a speed/pitch/special effect (Nightcore, 8D,
    /// Tremolo…) or "None" leaves the user's manual equalizer settings intact
    /// instead of wiping them. Only effects that actually define an EQ curve
    /// (`eqEnabled`, e.g. Bass Boost / Rock / Lo-Fi) overwrite the equalizer.
    static func apply(effect: AudioEffect, to settings: AudioSettings) -> AudioSettings {
        var s = settings
        // Only override the user's speed/pitch when this effect actually
        // defines a deliberate tempo/pitch change (nightcore, vaporwave,
        // slowmo, doubletime, pitchUp/Down, ...) — most effects (EQ curves,
        // spatial/reverb-only modes, and "None") declare the neutral values
        // (1.0 / 0.0) simply because every AudioEffect must set *some*
        // speed/pitchSemitones, not because they mean to reset whatever the
        // user already dialed in on the Speed/Pitch sliders. Applying (or
        // clearing, via the "None" effect) one of those neutral effects used
        // to silently snap speed/pitch back to default — this mirrors the
        // same "only touch it if this effect actually defines it" rule the
        // EQ branch below already uses.
        if effect.speed != 1.0 {
            s.speed = effect.speed
        }
        if effect.pitchSemitones != 0.0 {
            s.pitchSemitones = effect.pitchSemitones
        }
        s.activeEffectID = effect.id
        if effect.eqEnabled {
            s.equalizerEnabled = true
            s.eqBands = effect.eqBands
            // Mark the preset as custom so the EQ chip strip doesn't highlight a
            // mismatched preset while an EQ-based audio effect is active.
            s.eqPreset = .custom
        }
        // Non-EQ effects (and "None") preserve the user's existing EQ so the
        // equalizer keeps working alongside the effect + reverb.
        return s
    }
}
