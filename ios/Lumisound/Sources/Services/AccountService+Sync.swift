import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Sync

    /// Call schedulePush instead of this directly — it debounces rapid mutations.
    func pushSync(
        library: LibraryManager,
        audioSettings: AudioSettings? = nil,
        trackAudioSettings: [String: AudioSettings]? = nil
    ) async {
        guard isLoggedIn else { return }
        appLog("Push sync started (favorites: \(library.favoriteSongIDs.count), playlists: \(library.playlists.count))", category: "account")
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        // Build favorites from library
        let favorites = library.favoriteSongs.map { song in
            SyncFavorite(
                songId: song.id,
                title: song.title,
                artist: song.artistName,
                album: song.albumName
            )
        }

        // Build playlists from library
        let playlists = library.playlists.map { playlist -> SyncPlaylist in
            let songs = playlist.songIDs.compactMap { id in
                library.allSongs.first { $0.id == id }
            }
            let tracks = songs.enumerated().map { idx, song in
                SyncTrack(
                    localSongId: song.id,
                    trackUrl: song.url?.absoluteString,
                    title: song.title,
                    artist: song.artist.isEmpty ? nil : song.artist,
                    album: song.album.isEmpty ? nil : song.album,
                    durationSeconds: Int(song.duration),
                    position: idx
                )
            }
            return SyncPlaylist(
                id: playlist.id.uuidString,
                name: playlist.name,
                description: nil,
                folder: playlist.folder,
                tags: playlist.tags,
                tracks: tracks
            )
        }

        // Serialize audio settings to JSON if provided
        let audioJSON: String? = audioSettings.flatMap { settings in
            (try? JSONEncoder().encode(settings)).flatMap { String(data: $0, encoding: .utf8) }
        }
        // Serialize per-track audio settings overrides to JSON if provided
        let trackAudioJSON: String? = trackAudioSettings.flatMap { map in
            (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) }
        }
        // Read current accent colour from UserDefaults (saved by AppTheme.saveAccentColor)
        let themeHex: String? = {
            guard let data = UserDefaults.standard.data(forKey: "accent_color_data"),
                  let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data)
            else { return nil }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
        }()

        let defaults = UserDefaults.standard

        // Visual/layout preferences — mirrored from ios_user_settings_expanded
        // columns so they round-trip through the normal sync push/pull too.
        // "Vinyl disc enabled" maps to the legacy `nowPlaying_showVinylDisc`
        // bool if present (NowPlayingView migrates it to nowPlaying_artworkStyle
        // on first read), otherwise derive it from the current artwork style.
        let vinylDiscEnabled: Bool? = {
            if let legacy = defaults.object(forKey: "nowPlaying_showVinylDisc") as? Bool {
                return legacy
            }
            if let style = defaults.string(forKey: "nowPlaying_artworkStyle") {
                return style == "vinylDisc"
            }
            return nil
        }()
        let showQueuePreview: Bool? = defaults.object(forKey: "nowPlaying_showQueuePreview") != nil
            ? defaults.bool(forKey: "nowPlaying_showQueuePreview") : nil
        let songsPerRow: Int? = defaults.object(forKey: "library_songs_columns") != nil
            ? defaults.integer(forKey: "library_songs_columns") : nil
        let albumsPerRow: Int? = defaults.object(forKey: "library_albums_columns") != nil
            ? defaults.integer(forKey: "library_albums_columns") : nil
        let bgAnimation = defaults.string(forKey: "bgService.animation")
        let bgOpacity: Double? = defaults.object(forKey: "bgService.opacity") != nil
            ? defaults.double(forKey: "bgService.opacity") : nil
        let bgEnabled: Bool? = defaults.object(forKey: "bgService.isEnabled") != nil
            ? defaults.bool(forKey: "bgService.isEnabled") : nil
        let bgBlurRadius: Double? = defaults.object(forKey: "bgService.blurRadius") != nil
            ? defaults.double(forKey: "bgService.blurRadius") : nil
        let bgShuffleInterval: Double? = defaults.object(forKey: "bgService.shuffleInterval") != nil
            ? defaults.double(forKey: "bgService.shuffleInterval") : nil
        let preferredAudioFormat = defaults.string(forKey: StreamingService.preferredFormatKey)
        let downloadPath = defaults.string(forKey: StreamingService.downloadPathKey)

        // New sync fields
        let carModeEnabled: Bool? = defaults.object(forKey: "carModeEnabled") != nil
            ? defaults.bool(forKey: "carModeEnabled") : nil
        let libraryArtistsColumns: Int? = defaults.object(forKey: "library_artists_columns") != nil
            ? defaults.integer(forKey: "library_artists_columns") : nil
        let nowPlayingArtworkStyle = defaults.string(forKey: "nowPlaying_artworkStyle")
        let nowPlayingSeekerStyle = defaults.string(forKey: "nowPlaying_seekerStyle")
        let earnedBadgesJSON: String? = {
            guard let data = defaults.data(forKey: "earnedBadges"),
                  let decoded = try? JSONDecoder().decode(Set<String>.self, from: data),
                  !decoded.isEmpty
            else { return nil }
            return (try? JSONEncoder().encode(decoded)).flatMap { String(data: $0, encoding: .utf8) }
        }()

        // Previously device-local-only stores — see SyncData's doc comments
        // on each field for why these were gaps.
        let playHistoryJSON: String? = {
            let entries = PlayHistoryStore.shared.entries
            guard !entries.isEmpty else { return nil }
            return (try? JSONEncoder().encode(entries)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        let smartPlaylistsJSON: String? = {
            let playlists = SmartPlaylistStore.shared.playlists
            guard !playlists.isEmpty else { return nil }
            return (try? JSONEncoder().encode(playlists)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        let trackedPlaylistsJSON: String? = {
            let playlists = TrackedPlaylistStore.shared.playlists
            guard !playlists.isEmpty else { return nil }
            return (try? JSONEncoder().encode(playlists)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        let bookmarksJSON: String? = {
            let bookmarks = BookmarkStore.shared.bookmarksBySong
            guard !bookmarks.isEmpty else { return nil }
            return (try? JSONEncoder().encode(bookmarks)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        let bpmBySourceTrackIDJSON: String? = {
            var map: [String: Double] = [:]
            for song in library.allSongs {
                guard let sourceID = song.sourceTrackID, let bpm = song.bpm else { continue }
                map[sourceID] = bpm
            }
            guard !map.isEmpty else { return nil }
            return (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) }
        }()

        let payload = SyncData(
            favorites: favorites,
            playlists: playlists,
            audioSettingsJSON: audioJSON,
            trackAudioSettingsJSON: trackAudioJSON,
            themeColor: themeHex ?? "#EC4079",
            vinylDiscEnabled: vinylDiscEnabled,
            showQueuePreview: showQueuePreview,
            songsPerRow: songsPerRow,
            albumsPerRow: albumsPerRow,
            bgAnimation: bgAnimation,
            bgOpacity: bgOpacity,
            bgEnabled: bgEnabled,
            bgBlurRadius: bgBlurRadius,
            bgShuffleInterval: bgShuffleInterval,
            preferredAudioFormat: preferredAudioFormat,
            downloadPath: downloadPath,
            carModeEnabled: carModeEnabled,
            libraryArtistsColumns: libraryArtistsColumns,
            nowPlayingArtworkStyle: nowPlayingArtworkStyle,
            nowPlayingSeekerStyle: nowPlayingSeekerStyle,
            earnedBadgesJSON: earnedBadgesJSON,
            extraSettingsJSON: Self.buildExtraSettingsJSON(),
            playHistoryJSON: playHistoryJSON,
            smartPlaylistsJSON: smartPlaylistsJSON,
            trackedPlaylistsJSON: trackedPlaylistsJSON,
            bookmarksJSON: bookmarksJSON,
            bpmBySourceTrackIDJSON: bpmBySourceTrackIDJSON
        )

        do {
            // Retried, because the push is an idempotent upsert — the server
            // REPLACES this account's favourites and playlists with what is sent,
            // so sending it twice is indistinguishable from sending it once.
            //
            // Previously a single timeout abandoned the push entirely. Nothing was
            // permanently lost (a 20-minute safety-net timer re-pushes) but the
            // account stayed stale on every other device until it fired, and the
            // payload is tiny — 140 favourites and one playlist for the largest
            // account here — so these were ordinary network blips, not requests too
            // big to finish. Three attempts with backoff cover a blip in seconds
            // instead of twenty minutes.
            _ = try await NetworkRetry.withRetry(maxAttempts: 3, baseDelay: 0.8) {
                try await makeRequest("/user/sync", method: "POST", body: payload)
            }
            lastSyncDate = Date()
            // The server broadcasts a "sync_changed" live event to every one
            // of this account's active connections after a successful push —
            // including this same device's own /ws/live socket. Without this
            // timestamp, that echo would trigger an immediate, redundant
            // pullSync of the data this device just uploaded. See
            // `handleLiveSyncChanged`.
            lastPushCompletedAt = Date()
            appLog("Push sync complete", category: "account")
        } catch let err as AccountError {
            appError("Push sync failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
        } catch {
            // `schedulePush` cancels the *previous* debounce task whenever
            // called again before it fires — a URLSession request already
            // in flight from that superseded call surfaces here as
            // `URLError.cancelled`, not a real failure (the next debounced
            // call already covers it). Logging that as an error and
            // surfacing "cancelled" as errorMessage was pure noise: this one
            // pattern alone produced 500+ false-positive error-log entries
            // in a single day with nothing actually wrong. Log it quietly
            // and leave errorMessage untouched instead.
            if (error as? URLError)?.code == .cancelled {
                appLog("Push sync superseded by a newer sync (expected)", category: "account")
                return
            }
            // A transport failure that survived the retries above is reported but
            // NOT surfaced to the user. `errorMessage` has visible homes in the UI,
            // and telling someone their account failed to sync over a dropped
            // connection — which the safety-net timer will quietly fix, and which
            // they can do nothing about — is alarming without being useful. A real
            // server rejection still surfaces: that is the `AccountError` branch
            // above, where the status code means something actionable.
            let isTransport = error is URLError
            appError("Push sync error: \(error.localizedDescription)"
                     + (isTransport ? " (transient, will retry on the next sync)" : ""),
                     category: "account")
            if !isTransport {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Additional UserDefaults-backed preference keys (and their value type)
    /// included in the per-user auto backup beyond the explicitly-modelled
    /// SyncData columns. Backed up/restored as a single JSON bag
    /// (`extra_settings_json`). Adding a new backed-up preference is a one-line
    /// addition here.
    static let extraBackupKeys: [(key: String, kind: ExtraSettingKind)] = [
        ("library_cardStyle", .string),
        ("autoRadio_enabled", .bool),
        ("notifications_enabled", .bool),
        ("ytdlp_use_aria2", .bool),
        // Liquid Glass customization (see GlassSettings)
        ("glass_tintStrength", .double),
        ("glass_tintHue", .double),
        ("glass_useAccentTint", .bool),
        ("glass_translucency", .double),
        // Remaining per-tab grid column counts — songs/albums/artists were
        // already covered above via dedicated SyncData columns; these were
        // simply never added when those later tabs picked up the same
        // list/grid toggle.
        ("library_favorites_columns", .int),
        ("library_genres_columns", .int),
        ("library_folders_columns", .int),
        ("folderDetail_columns", .int),
        ("albumDetail_columns", .int),
        // Appearance customization (Settings → Appearance) — only accent
        // color was covered before; a user who customized background theme/
        // font/launch screen/transitions/panel style lost the rest on a
        // fresh install.
        ("app_background_theme", .string),
        ("app_font_style", .string),
        ("launch_screen_style", .string),
        ("tab_transition_style", .string),
        ("panel_material_style", .string),
        ("panel_opacity", .double),
        ("app_reduce_motion", .bool),
        // yt-dlp download tuning beyond the aria2 toggle, and the
        // "auto-backup downloads to cloud" preference.
        ("ytdlp_download_folder", .string),
        ("ytdlp_throttle_seconds", .int),
        ("ytdlp_concurrent_fragments", .int),
        ("autoCloudBackup", .bool),
        // Custom navbar layout (Settings → Appearance → Navbar) — a user who
        // hid tabs, switched selection style, or turned off tab labels lost
        // all of it on a fresh install; only the artwork/seeker style
        // preferences (dedicated SyncData columns) survived before this.
        ("navbarDisplayMode", .string),
        ("navbarShowTabLabels", .bool),
        ("navbarSelectionStyle", .string),
        ("navbarHiddenTabs", .string),
        // Gallery Background source + Ken Burns — the source picker
        // (Photos/Sonic Wallpaper/Reactive Aura) and motion toggle were
        // never backed up; only the photo-specific animation/opacity/blur
        // settings (dedicated SyncData columns) were.
        (GalleryBackgroundSource.storageKey, .string),
        ("bgService.kenBurnsEnabled", .bool),
        // Home hub customization (reorder/hide sections, custom greeting,
        // accent) — entirely unbacked-up before this; a reinstall silently
        // reset a customized Home tab back to its default layout.
        (HomeHubLayoutStore.orderKey, .string),
        (HomeHubLayoutStore.hiddenKey, .string),
        ("home_hub_custom_greeting", .string),
        ("home_hub_accent_hex", .string),
        // Wi-Fi-only downloads — a real user preference (avoids burning
        // cellular data on auto-downloads), previously device-local only.
        ("wifiOnlyDownloads.enabled", .bool),
    ]

    enum ExtraSettingKind { case bool, double, string, int }

    /// Serializes the current values of `extraBackupKeys` (only those actually
    /// set) into a JSON object string for the backup payload.
    static func buildExtraSettingsJSON() -> String? {
        let defaults = UserDefaults.standard
        var dict: [String: Any] = [:]
        for entry in extraBackupKeys {
            guard defaults.object(forKey: entry.key) != nil else { continue }
            switch entry.kind {
            case .bool:   dict[entry.key] = defaults.bool(forKey: entry.key)
            case .double: dict[entry.key] = defaults.double(forKey: entry.key)
            case .int:    dict[entry.key] = defaults.integer(forKey: entry.key)
            case .string: dict[entry.key] = defaults.string(forKey: entry.key)
            }
        }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Restores backed-up extra settings, writing each key only when it's not
    /// already set locally — first-run/new-device bootstrap only, mirroring the
    /// non-destructive restore policy used for the other synced settings (see
    /// the destructive-pull-sync fix) so a fresher local value is never
    /// clobbered by a stale server one.
    static func applyExtraSettingsJSON(_ json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let defaults = UserDefaults.standard
        for entry in extraBackupKeys {
            guard defaults.object(forKey: entry.key) == nil, let value = dict[entry.key] else { continue }
            switch entry.kind {
            case .bool:   if let b = value as? Bool   { defaults.set(b, forKey: entry.key) }
            case .double: if let d = value as? Double { defaults.set(d, forKey: entry.key) }
                          else if let n = value as? NSNumber { defaults.set(n.doubleValue, forKey: entry.key) }
            case .int:    if let i = value as? Int    { defaults.set(i, forKey: entry.key) }
                          else if let n = value as? NSNumber { defaults.set(n.intValue, forKey: entry.key) }
            case .string: if let s = value as? String { defaults.set(s, forKey: entry.key) }
            }
        }
    }

    func pullSync(library: LibraryManager, player: AudioPlayerManager? = nil) async {
        guard isLoggedIn else { return }
        appLog("Pull sync started", category: "account")
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        do {
            let data = try await makeRequest("/user/sync")
            let sync = try JSONDecoder().decode(SyncData.self, from: data)

            // Apply favorites: merge remote into local — add anything missing locally.
            //
            // This used to be a destructive "toggle to match remote exactly", which
            // also *removed* any local favorite absent from the server payload. That
            // silently wiped out the user's likes whenever the remote was behind the
            // device (e.g. the previous session's pushSync hadn't completed before
            // the app was terminated, or ran against a flaky connection) — which is
            // exactly what showed up as "app data doesn't seem to hold anything
            // locally". Only ever add; the merged superset gets pushed back up by
            // the `.onChange(of: favoriteSongIDs)` → schedulePush handler, so both
            // sides converge without data loss.
            let remoteIDs = Set(sync.favorites.map { $0.songId })
            let localFavorites = library.favoriteSongIDs
            let toAdd = remoteIDs.subtracting(localFavorites)
            // `addFavorites` (one persistence write, one toast) instead of
            // looping `toggleFavorite` once per id: this pull runs on every
            // launch/foreground while logged in — the "auto reload" users
            // reported as freezing the whole app — and `toggleFavorite`
            // does a synchronous disk write PLUS pops a toast on every
            // single call. With hundreds of favorites that's hundreds of
            // synchronous writes and toast animations firing back-to-back
            // on the main actor with no `await` in between to yield at, a
            // real multi-second block on all interaction, not just a
            // rendering-cost issue.
            if !toAdd.isEmpty { library.addFavorites(ids: toAdd) }

            // Apply playlists: merge server playlists (add missing by name, skip existing).
            // Same fix as favorites above: build each new playlist's full
            // song id list first and create it in one `createPlaylist(name:songIDs:)`
            // call (one write, no toast — same helper M3U import already
            // uses for this exact "several tracks into a fresh playlist"
            // shape) instead of `createPlaylist(name:)` + one `addSong`
            // call per track, which was the dominant cost here for anyone
            // with sizable playlists — a 500-track playlist meant 500
            // synchronous writes/toasts for that ONE playlist alone.
            let existingNames = Set(library.playlists.map { $0.name })
            for sp in sync.playlists {
                guard !existingNames.contains(sp.name) else { continue }
                let songIDs = sp.tracks.compactMap { $0.localSongId }
                let newPL = library.createPlaylist(name: sp.name, songIDs: songIDs)
                if sp.folder != nil { library.setFolder(sp.folder, forPlaylistID: newPL.id) }
                if !sp.tags.isEmpty { library.setTags(sp.tags, forPlaylistID: newPL.id) }
            }

            // Restore audio settings from DB — but only as a first-run/new-device
            // bootstrap (no local settings yet). Unconditionally overwriting local
            // settings with whatever the server last received clobbers more recent
            // local changes whenever a previous pushSync didn't finish before the
            // app was terminated (the debounced 2s push is easy to race on app
            // close), which presents to the user as "my settings keep resetting /
            // don't actually save". The local copy — which `onChange` keeps pushed
            // up via schedulePush — is always at least as fresh as the server's.
            if PersistenceService.shared.loadAudioSettings() == nil,
               let json = sync.audioSettingsJSON,
               let jsonData = json.data(using: .utf8),
               let restoredSettings = try? JSONDecoder().decode(AudioSettings.self, from: jsonData) {
                PersistenceService.shared.saveAudioSettings(restoredSettings)
                // Signal the player to apply them (observers in LumisoundApp reload on launch)
            }

            // Restore per-track audio settings overrides — same first-run-only
            // guard as the global audio settings above, to avoid clobbering
            // settings saved locally since the last successful push.
            if PersistenceService.shared.loadTrackAudioSettings().isEmpty,
               let json = sync.trackAudioSettingsJSON,
               let jsonData = json.data(using: .utf8),
               let restoredMap = try? JSONDecoder().decode([String: AudioSettings].self, from: jsonData),
               !restoredMap.isEmpty {
                if let player {
                    player.restorePerTrackAudioSettings(restoredMap)
                } else {
                    PersistenceService.shared.saveTrackAudioSettings(restoredMap)
                }
            }

            // Restore theme colour — same first-run-only guard as audio settings above:
            // there's no `.onChange` hook pushing accent-colour changes immediately
            // (it only rides along on the next favorites/playlist/settings push), so
            // an unconditional overwrite here would routinely revert a just-picked
            // colour back to whatever stale value the server last happened to receive.
            if UserDefaults.standard.data(forKey: "accent_color_data") == nil,
               let hex = sync.themeColor, hex.hasPrefix("#"), hex.count == 7 {
                let scanner = Scanner(string: String(hex.dropFirst()))
                var rgb: UInt64 = 0
                if scanner.scanHexInt64(&rgb) {
                    let r = CGFloat((rgb >> 16) & 0xFF) / 255
                    let g = CGFloat((rgb >> 8)  & 0xFF) / 255
                    let b = CGFloat( rgb        & 0xFF) / 255
                    AppTheme.saveAccentColor(Color(red: r, green: g, blue: b))
                }
            }

            // Restore expanded visual/layout preferences and the new sync
            // fields — same first-run-only guard as audio settings/theme above:
            // only apply when the local UserDefaults key is unset, so a fresher
            // local change is never clobbered by a stale server value.
            let defaults = UserDefaults.standard

            if defaults.object(forKey: "nowPlaying_showVinylDisc") == nil,
               defaults.string(forKey: "nowPlaying_artworkStyle") == nil,
               let vinylDiscEnabled = sync.vinylDiscEnabled {
                defaults.set(vinylDiscEnabled, forKey: "nowPlaying_showVinylDisc")
            }
            if defaults.object(forKey: "nowPlaying_showQueuePreview") == nil,
               let showQueuePreview = sync.showQueuePreview {
                defaults.set(showQueuePreview, forKey: "nowPlaying_showQueuePreview")
            }
            if defaults.object(forKey: "library_songs_columns") == nil,
               let songsPerRow = sync.songsPerRow {
                defaults.set(songsPerRow, forKey: "library_songs_columns")
            }
            if defaults.object(forKey: "library_albums_columns") == nil,
               let albumsPerRow = sync.albumsPerRow {
                defaults.set(albumsPerRow, forKey: "library_albums_columns")
            }
            if defaults.string(forKey: "bgService.animation") == nil,
               let bgAnimation = sync.bgAnimation {
                defaults.set(bgAnimation, forKey: "bgService.animation")
            }
            if defaults.object(forKey: "bgService.opacity") == nil,
               let bgOpacity = sync.bgOpacity {
                defaults.set(bgOpacity, forKey: "bgService.opacity")
            }
            if defaults.object(forKey: "bgService.isEnabled") == nil,
               let bgEnabled = sync.bgEnabled {
                defaults.set(bgEnabled, forKey: "bgService.isEnabled")
            }
            if defaults.object(forKey: "bgService.blurRadius") == nil,
               let bgBlurRadius = sync.bgBlurRadius {
                defaults.set(bgBlurRadius, forKey: "bgService.blurRadius")
            }
            if defaults.object(forKey: "bgService.shuffleInterval") == nil,
               let bgShuffleInterval = sync.bgShuffleInterval {
                defaults.set(bgShuffleInterval, forKey: "bgService.shuffleInterval")
            }
            // Re-apply the (possibly just-updated) gallery background settings to
            // the live BackgroundService instance — without this, a value written
            // to UserDefaults above sits unused until the next app launch, and the
            // very next `didSet` on the running instance (e.g. opening the
            // background settings screen) immediately pushes its still-old
            // in-memory value back to the server, overwriting what was just pulled.
            BackgroundService.shared?.loadSettings()
            if defaults.string(forKey: StreamingService.preferredFormatKey) == nil,
               let preferredAudioFormat = sync.preferredAudioFormat {
                defaults.set(preferredAudioFormat, forKey: StreamingService.preferredFormatKey)
            }
            if defaults.string(forKey: StreamingService.downloadPathKey) == nil,
               let downloadPath = sync.downloadPath {
                defaults.set(downloadPath, forKey: StreamingService.downloadPathKey)
            }
            if defaults.object(forKey: "carModeEnabled") == nil,
               let carModeEnabled = sync.carModeEnabled {
                defaults.set(carModeEnabled, forKey: "carModeEnabled")
            }
            if defaults.object(forKey: "library_artists_columns") == nil,
               let libraryArtistsColumns = sync.libraryArtistsColumns {
                defaults.set(libraryArtistsColumns, forKey: "library_artists_columns")
            }
            if defaults.string(forKey: "nowPlaying_artworkStyle") == nil,
               let nowPlayingArtworkStyle = sync.nowPlayingArtworkStyle {
                defaults.set(nowPlayingArtworkStyle, forKey: "nowPlaying_artworkStyle")
            }
            if defaults.string(forKey: "nowPlaying_seekerStyle") == nil,
               let nowPlayingSeekerStyle = sync.nowPlayingSeekerStyle {
                defaults.set(nowPlayingSeekerStyle, forKey: "nowPlaying_seekerStyle")
            }

            // Earned badges: UNION merge with local regardless of whether local
            // already has a value — badges should never be "lost" by syncing
            // from a device that hasn't unlocked them all yet.
            if let json = sync.earnedBadgesJSON,
               let jsonData = json.data(using: .utf8),
               let remoteBadges = try? JSONDecoder().decode(Set<String>.self, from: jsonData),
               !remoteBadges.isEmpty {
                var localBadges: Set<String> = []
                if let stored = defaults.data(forKey: "earnedBadges"),
                   let decoded = try? JSONDecoder().decode(Set<String>.self, from: stored) {
                    localBadges = decoded
                }
                let merged = localBadges.union(remoteBadges)
                if merged != localBadges,
                   let encoded = try? JSONEncoder().encode(merged) {
                    defaults.set(encoded, forKey: "earnedBadges")
                }
            }

            // Restore any additional backed-up preferences (card style,
            // auto-radio, notifications, Liquid Glass customization, …) — only
            // for keys not already set locally (new-device bootstrap).
            Self.applyExtraSettingsJSON(sync.extraSettingsJSON)

            // Restore previously device-local-only stores. Each has its own
            // merge policy (see the store's mergeFromSync doc comment) —
            // none of these are a blind overwrite, so a fresher local value
            // is never clobbered the same way audio settings/theme above
            // are guarded against it.
            if let json = sync.playHistoryJSON, let jsonData = json.data(using: .utf8),
               let remote = try? JSONDecoder().decode([String: PlayHistoryEntry].self, from: jsonData) {
                PlayHistoryStore.shared.mergeFromSync(remote)
            }
            if let json = sync.smartPlaylistsJSON, let jsonData = json.data(using: .utf8),
               let remote = try? JSONDecoder().decode([SmartPlaylist].self, from: jsonData) {
                SmartPlaylistStore.shared.mergeFromSync(remote)
            }
            if let json = sync.trackedPlaylistsJSON, let jsonData = json.data(using: .utf8),
               let remote = try? JSONDecoder().decode([TrackedPlaylist].self, from: jsonData) {
                TrackedPlaylistStore.shared.mergeFromSync(remote)
            }
            if let json = sync.bookmarksJSON, let jsonData = json.data(using: .utf8),
               let remote = try? JSONDecoder().decode([String: [TrackBookmark]].self, from: jsonData) {
                BookmarkStore.shared.mergeFromSync(remote)
            }
            if let json = sync.bpmBySourceTrackIDJSON, let jsonData = json.data(using: .utf8),
               let remote = try? JSONDecoder().decode([String: Double].self, from: jsonData), !remote.isEmpty {
                for song in library.allSongs {
                    guard song.bpm == nil, let sourceID = song.sourceTrackID, let bpm = remote[sourceID] else { continue }
                    library.storeBPM(bpm, for: song.id)
                }
            }

            lastSyncDate = Date()
            appLog("Pull sync complete (favorites: \(remoteIDs.count), playlists: \(sync.playlists.count))", category: "account")
        } catch let err as AccountError {
            appError("Pull sync failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
        } catch {
            appError("Pull sync error: \(error.localizedDescription)", category: "account")
            errorMessage = error.localizedDescription
        }
    }
}
