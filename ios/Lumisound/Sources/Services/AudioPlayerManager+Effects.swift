@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Audio Effects

    func applyEffect(_ effect: AudioEffect) {
        appLog("Effect applied: \(effect.name) (id: \(effect.id))", category: "audio")
        // Stop all running special effects before switching to a new one.
        stop8DRotation()
        stopTremolo()
        stopVibrato()

        // Apply static EQ / speed / pitch settings.
        var s = AudioEffectsService.apply(effect: effect, to: audioSettings)
        s.activeEffectID = effect.id
        audioSettings = s   // triggers didSet → applyAudioSettings()

        // Start the special mode for this effect.
        switch effect.specialMode.type {
        case .rotation:
            start8DRotation(hz: effect.specialMode.hz)
        case .tremolo:
            startTremolo(frequency: effect.specialMode.freq, depth: effect.specialMode.depth)
        case .vibrato:
            startVibrato(frequency: effect.specialMode.freq, depth: effect.specialMode.pitchDepth)
        case .none:
            break
        }
    }

    /// Re-starts any dynamic effect (8D, tremolo, vibrato) that was active before
    /// playback began. Called after the engine starts so CADisplayLink effects actually run.
    func reapplyActiveEffect() {
        let effectID = audioSettings.activeEffectID
        guard !effectID.isEmpty, effectID != "none" else { return }
        let effect: AudioEffect?
        if let ref = LuaEffectEngine.scriptRef(forEffectID: effectID) {
            effect = try? LuaEffectEngine.resolve(ref, track: currentSong)
        } else {
            effect = AudioEffectsService.allEffects.first(where: { $0.id == effectID })
        }
        guard let effect else { return }
        switch effect.specialMode.type {
        case .rotation:
            if !is8DActive { start8DRotation(hz: effect.specialMode.hz) }
        case .tremolo:
            if !isTremoloActive { startTremolo(frequency: effect.specialMode.freq, depth: effect.specialMode.depth) }
        case .vibrato:
            if !isVibratoActive { startVibrato(frequency: effect.specialMode.freq, depth: effect.specialMode.pitchDepth) }
        case .none:
            break
        }
    }

    // MARK: - EQ Presets

    func applyEQPreset(_ preset: EQPreset) {
        var settings = audioSettings
        settings.eqPreset = preset
        if preset != .custom {
            settings.eqBands = preset.bands
        }
        settings.equalizerEnabled = preset != .flat
        audioSettings = settings   // triggers didSet → applyAudioSettings()
    }
}
