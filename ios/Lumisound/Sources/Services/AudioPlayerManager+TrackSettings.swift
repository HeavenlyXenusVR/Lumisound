@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Per-Track Audio Settings

    /// Called whenever `currentSong` changes to a different track. Saves the
    /// outgoing track's settings (if it had a custom override active) and loads
    /// the incoming track's saved override, falling back to the global default.
    func applyTrackAudioSettings(previousID: String?) {
        if let previousID, isUsingTrackAudioSettings {
            perTrackAudioSettings[previousID] = audioSettings
            PersistenceService.shared.saveTrackAudioSettings(perTrackAudioSettings)
        }

        isSwitchingTrack = true
        if let id = currentSong?.id, let saved = perTrackAudioSettings[id] {
            // A specific track's own override always wins over whatever
            // playlist it happens to be playing from.
            isUsingTrackAudioSettings = true
            audioSettings = saved
        } else if let playlistID = currentPlaylistID,
                  let playlistOverride = libraryManager?.playlists.first(where: { $0.id == playlistID })?.audioSettingsOverride {
            isUsingTrackAudioSettings = false
            audioSettings = playlistOverride
        } else {
            isUsingTrackAudioSettings = false
            audioSettings = defaultAudioSettings
        }
        isSwitchingTrack = false
    }

    /// Saves the current `audioSettings` (EQ, effects, volume, etc.) as a
    /// per-track override for the currently playing song, so they're recalled
    /// automatically the next time this track plays.
    func saveAudioSettingsForCurrentTrack() {
        guard let id = currentSong?.id else { return }
        isUsingTrackAudioSettings = true
        perTrackAudioSettings[id] = audioSettings
        PersistenceService.shared.saveTrackAudioSettings(perTrackAudioSettings)
        onTrackAudioSettingsChanged?()
    }

    /// Removes the saved per-track override for the currently playing song and
    /// reverts playback to the global default settings.
    func clearAudioSettingsForCurrentTrack() {
        guard let id = currentSong?.id, perTrackAudioSettings[id] != nil else { return }
        perTrackAudioSettings.removeValue(forKey: id)
        PersistenceService.shared.saveTrackAudioSettings(perTrackAudioSettings)
        isUsingTrackAudioSettings = false
        isSwitchingTrack = true
        audioSettings = defaultAudioSettings
        isSwitchingTrack = false
        onTrackAudioSettingsChanged?()
    }

    /// Called once at launch to restore the user's global default audio settings
    /// from disk. `restorePlaybackState()` (called earlier, during `init()`) may
    /// already have switched `audioSettings` to a per-track override for the
    /// restored `currentSong` — in that case only `defaultAudioSettings` is
    /// updated here, leaving the active per-track settings in place.
    func restoreDefaultAudioSettings(_ settings: AudioSettings) {
        defaultAudioSettings = settings
        guard !isUsingTrackAudioSettings else { return }
        isSwitchingTrack = true
        audioSettings = settings
        isSwitchingTrack = false
    }

    /// Replaces the entire per-track settings map (used when restoring from a
    /// server sync). If the currently playing track has an override in the new
    /// map, it's applied immediately.
    func restorePerTrackAudioSettings(_ map: [String: AudioSettings]) {
        perTrackAudioSettings = map
        PersistenceService.shared.saveTrackAudioSettings(map)
        if let id = currentSong?.id, let saved = map[id] {
            isUsingTrackAudioSettings = true
            isSwitchingTrack = true
            audioSettings = saved
            isSwitchingTrack = false
        }
    }
}
