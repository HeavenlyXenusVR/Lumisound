import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Per-Track Audio Settings

    /// Lets the user pin the current EQ/effects/volume/etc. (`player.audioSettings`)
    /// to this specific track, so they're recalled automatically every time it
    /// plays — independent of the global default settings used for other tracks.
    var trackAudioSettingsSection: some View {
        Group {
            if player.currentSong != nil {
                HStack(spacing: 12) {
                    Image(systemName: player.isUsingTrackAudioSettings ? "pin.fill" : "pin")
                        .font(.system(size: 16))
                        .foregroundStyle(player.isUsingTrackAudioSettings ? AppTheme.dynamicAccent : AppTheme.textSecondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.isUsingTrackAudioSettings ? "Custom Sound for This Track" : "Using Default Sound Settings")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(player.isUsingTrackAudioSettings
                             ? "EQ, effects, and volume are saved just for this track."
                             : "Save the current EQ/effects/volume to use only for this track.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        selectHaptic.selectionChanged()
                        if player.isUsingTrackAudioSettings {
                            player.clearAudioSettingsForCurrentTrack()
                        } else {
                            player.saveAudioSettingsForCurrentTrack()
                        }
                    } label: {
                        Text(player.isUsingTrackAudioSettings ? "Remove" : "Save")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                player.isUsingTrackAudioSettings ? AppTheme.elevatedSurface : AppTheme.dynamicAccent,
                                in: Capsule()
                            )
                            .foregroundStyle(player.isUsingTrackAudioSettings ? AppTheme.textPrimary : .white)
                    }
                    .buttonStyle(.plain)
                }
                .panelStyle()
            }

            playlistAudioSettingsSection
        }
    }

    // MARK: - Playlist-Level Audio Settings

    /// Same idea one level up — see `Playlist.audioSettingsOverride`. Only
    /// shown when the current track is actually playing as part of a
    /// playlist (`player.currentPlaylistID`); a track's own pin above
    /// always takes priority over this when both exist.
    @ViewBuilder
    private var playlistAudioSettingsSection: some View {
        if let playlistID = player.currentPlaylistID,
           let playlist = library.playlists.first(where: { $0.id == playlistID }) {
            let hasOverride = playlist.audioSettingsOverride != nil
            HStack(spacing: 12) {
                Image(systemName: hasOverride ? "music.note.list" : "music.note.list")
                    .font(.system(size: 16))
                    .foregroundStyle(hasOverride ? AppTheme.dynamicAccent : AppTheme.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hasOverride ? "Custom Sound for \"\(playlist.name)\"" : "Save Sound for This Playlist")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(hasOverride
                         ? "Every track in this playlist opens with this EQ/effects/volume, unless the track has its own pin above."
                         : "Save the current EQ/effects/volume as this playlist's default — every track in it will open with this sound.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer(minLength: 8)

                Button {
                    selectHaptic.selectionChanged()
                    if hasOverride {
                        library.clearAudioSettingsOverride(forPlaylistID: playlistID)
                    } else {
                        library.setAudioSettingsOverride(player.audioSettings, forPlaylistID: playlistID)
                    }
                } label: {
                    Text(hasOverride ? "Remove" : "Save")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(hasOverride ? AppTheme.elevatedSurface : AppTheme.dynamicAccent, in: Capsule())
                        .foregroundStyle(hasOverride ? AppTheme.textPrimary : .white)
                }
                .buttonStyle(.plain)
            }
            .panelStyle()
        }
    }
}
