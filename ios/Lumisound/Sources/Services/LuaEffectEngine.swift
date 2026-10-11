import Foundation

// MARK: - LuaEffectEngine
//
// User/community-scriptable audio effect presets — the Lua-scripted
// counterpart to `AudioEffectsService`'s 27 fixed native presets. A script
// assigns a global `effect` table (id, name, icon, eq_bands, eq_enabled,
// speed, pitch_semitones, special_mode) computed however the author likes —
// loops, math, conditionals — rather than 10 hardcoded dB values. The
// resolved result is a real `AudioEffect`, applied through the exact same
// `AudioPlayerManager.applyEffect(_:)` a native preset goes through — no
// parallel effect-application path.
enum LuaEffectEngine {
    private static let subdirectory = "LuaEffects"

    static func bundledScripts() -> [LuaUserScriptLibrary.ScriptRef] {
        LuaUserScriptLibrary.bundledScripts(subdirectory: subdirectory)
    }

    static func userScripts() -> [LuaUserScriptLibrary.ScriptRef] {
        LuaUserScriptLibrary.userScripts(subdirectory: subdirectory)
    }

    @discardableResult
    static func importScript(source: String, suggestedName: String) throws -> LuaUserScriptLibrary.ScriptRef {
        try LuaUserScriptLibrary.importScript(source: source, suggestedName: suggestedName, subdirectory: subdirectory)
    }

    static func deleteUserScript(_ ref: LuaUserScriptLibrary.ScriptRef) {
        LuaUserScriptLibrary.deleteUserScript(ref)
    }

    /// Looks a script up by its `AudioEffect.id` (`"lua:<script id>"`) across
    /// both bundled and user scripts — used to re-resolve a previously
    /// active Lua effect (e.g. after an app relaunch or when restarting a
    /// dynamic special mode; see `AudioPlayerManager.reapplyActiveEffect`).
    static func scriptRef(forEffectID effectID: String) -> LuaUserScriptLibrary.ScriptRef? {
        guard effectID.hasPrefix("lua:") else { return nil }
        let scriptID = String(effectID.dropFirst("lua:".count))
        return (bundledScripts() + userScripts()).first { $0.id == scriptID }
    }

    // MARK: - Resolution

    private struct EffectConfig: Decodable {
        struct SpecialModeConfig: Decodable {
            var type: String
            var hz: Double?
            var freq: Double?
            var depth: Double?
            var pitchDepth: Double?
        }
        var id: String
        var name: String
        var icon: String
        var eqBands: [Float]
        var eqEnabled: Bool
        var speed: Float
        var pitchSemitones: Float
        var specialMode: SpecialModeConfig?
    }

    enum EngineError: LocalizedError {
        case scriptNotReadable(String)
        case invalidBandCount(Int)

        var errorDescription: String? {
            switch self {
            case .scriptNotReadable(let name):
                return "Couldn't read the \u{201C}\(name)\u{201D} effect script."
            case .invalidBandCount(let count):
                return "Effect script returned \(count) EQ bands \u{2014} expected exactly 10."
            }
        }
    }

    /// What a script can read about the track it's about to apply to, via
    /// the global `track` table — nil (absent entirely, so `track == nil` in
    /// Lua) when resolving without a specific song (e.g. previewing a script
    /// from the list before anything's playing). Same field set and
    /// snake_case convention `LuaSmartPlaylistEngine`'s `SongFacts` already
    /// uses, so a script author already familiar with one recognizes the
    /// other immediately.
    private struct TrackContext: Encodable {
        var title: String
        var artist: String
        var album: String
        var genre: String
        var duration: Double
        var bpm: Double?
    }

    /// Runs `ref`'s script and resolves it into a real `AudioEffect`, ready
    /// to hand to `AudioPlayerManager.applyEffect(_:)`. The `id` on the
    /// returned effect is always `"lua:<script id>"` (ignoring whatever `id`
    /// the script itself set) so it can never collide with a native preset's
    /// id and is always traceable back to its source script.
    ///
    /// `track`, when given, is injected as a global `track` table BEFORE the
    /// script runs — this is what actually makes a script like "Genre
    /// Blend" able to react to the genre of what's ACTUALLY playing instead
    /// of only a knob the user sets by hand. `reapplyActiveEffect` already
    /// re-resolves the active Lua effect on every track start, so a script
    /// that reads `track` recomputes itself fresh per-song for free, with no
    /// change needed on the caller's side beyond passing the song.
    static func resolve(_ ref: LuaUserScriptLibrary.ScriptRef, track: Song? = nil) throws -> AudioEffect {
        guard let source = try? String(contentsOf: ref.url, encoding: .utf8) else {
            throw EngineError.scriptNotReadable(ref.displayName)
        }
        let trackPrelude: String
        if let track {
            let context = TrackContext(
                title: track.title,
                artist: track.artist,
                album: track.album,
                genre: track.genre,
                duration: track.duration,
                bpm: track.bpm
            )
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            guard let data = try? encoder.encode(context), let json = String(data: data, encoding: .utf8) else {
                throw EngineError.scriptNotReadable(ref.displayName)
            }
            trackPrelude = "local track = json.decode(\(LuaJSONBridge.quotedLuaString(json)))\n"
        } else {
            trackPrelude = "local track = nil\n"
        }
        let wrapped = trackPrelude + source + "\nreturn json.encode(effect)\n"
        let config = try LuaJSONBridge.run(wrapped, chunkName: ref.id, as: EffectConfig.self)
        guard config.eqBands.count == 10 else {
            throw EngineError.invalidBandCount(config.eqBands.count)
        }

        var specialMode = AudioEffectSpecialMode.none
        if let sm = config.specialMode {
            switch sm.type {
            case "rotation":
                specialMode = .rotation(hz: sm.hz ?? 0.18)
            case "tremolo":
                specialMode = .tremolo(freq: sm.freq ?? 4.0, depth: Float(sm.depth ?? 0.45))
            case "vibrato":
                specialMode = .vibrato(freq: sm.freq ?? 4.5, depth: sm.pitchDepth ?? 0.35)
            default:
                break
            }
        }

        return AudioEffect(
            id: "lua:\(ref.id)",
            name: config.name,
            icon: config.icon,
            eqBands: config.eqBands,
            eqEnabled: config.eqEnabled,
            speed: config.speed,
            pitchSemitones: config.pitchSemitones,
            specialMode: specialMode
        )
    }
}
