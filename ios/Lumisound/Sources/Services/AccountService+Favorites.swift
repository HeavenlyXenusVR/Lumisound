import Foundation

// MARK: - Favorites, tied to the account
//
// Favorites were stored ONLY in UserDefaults (`PersistenceService.saveFavorites`)
// and `/user/favorites` was never called from this app at all — the endpoint
// existed and the tvOS port had been using it, so the server already held rows
// this app could not see. That is why favorites vanished on uninstall, did not
// survive a reinstall, and did not follow the account onto another device: they
// had never left the device they were made on.
//
// Local storage stays as the source of truth for immediate reads — every row in
// the library asks `isFavorite` while rendering, and that has to be synchronous.
// The server is treated as the durable copy behind it: writes are mirrored up,
// and `mergeFavoritesFromServer` pulls the account's set down and unions it in.
//
// Union, not replace. A track favorited offline, or on a device that has not
// pushed yet, must not be deleted by a sync — losing a favorite is a far worse
// outcome than briefly keeping one the user removed elsewhere. Removals still
// propagate, because a DELETE is sent when one happens.
extension AccountService {

    /// Mirrors a single favorite change to the account. Fire-and-forget: the
    /// local write has already happened and the UI has already updated, so a
    /// failure here must never block or reverse that.
    func pushFavorite(songID: String, isFavorite: Bool, title: String?, artist: String?, album: String?) {
        guard token != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if isFavorite {
                    struct Body: Encodable {
                        let song_id: String
                        let title: String?
                        let artist: String?
                        let album: String?
                    }
                    _ = try await self.makeRequest(
                        "/user/favorites", method: "POST",
                        body: Body(song_id: songID, title: title, artist: artist, album: album)
                    )
                } else {
                    let encoded = songID.addingPercentEncoding(
                        withAllowedCharacters: .urlPathAllowed) ?? songID
                    _ = try await self.makeRequest("/user/favorites/\(encoded)", method: "DELETE")
                }
            } catch {
                appWarn("pushFavorite(\(songID), \(isFavorite)) failed: \(error.localizedDescription)",
                        category: "network")
            }
        }
    }

    /// Pulls the account's favorites and unions them into the local set.
    ///
    /// Called on launch and after sign-in, which is what actually restores them
    /// after a reinstall or on a new device.
    @MainActor
    func mergeFavoritesFromServer(into library: LibraryManager) async {
        guard token != nil else { return }
        struct Row: Decodable {
            let song_id: String
        }
        do {
            let data = try await makeRequest("/user/favorites")
            // `GET /user/favorites` returns a BARE ARRAY of rows, not an object
            // wrapping them.
            //
            // This decoded `{"favorites": [...]}`, a shape the endpoint has never
            // produced, so the decode threw every single time and this function
            // could not once do the job it exists for. Telemetry across all
            // signed-in accounts showed the same failure for 22 of them and zero
            // successes — favourites simply never came back from the account after
            // a reinstall or on a second device, which is the entire reason this
            // was written. tvOS reads the same endpoint as an array and was always
            // fine, which is why the mismatch stayed invisible on one platform.
            let decoded = try JSONDecoder().decode([Row].self, from: data)
            let remote = Set(decoded.map(\.song_id))
            guard !remote.isEmpty else { return }

            let before = library.favoriteSongIDs.count
            library.favoriteSongIDs.formUnion(remote)
            let added = library.favoriteSongIDs.count - before
            if added > 0 {
                library.persistence.saveFavorites(library.favoriteSongIDs)
            }

            // Anything held locally that the server does not know about is
            // pushed up, so a device that has been favoriting offline since
            // before this existed contributes its set rather than being the only
            // place it lives.
            let missingOnServer = library.favoriteSongIDs.subtracting(remote)
            for songID in missingOnServer {
                let song = library.songsByID[songID]
                pushFavorite(songID: songID, isFavorite: true,
                             title: song?.title, artist: song?.artist, album: song?.album)
            }

            appLog("mergeFavoritesFromServer: \(remote.count) on server, \(added) new locally, \(missingOnServer.count) pushed up",
                   category: "sync")
        } catch {
            appWarn("mergeFavoritesFromServer failed: \(error.localizedDescription)", category: "network")
        }
    }
}

// MARK: - Lyrics

extension AccountService {
    /// Stores lyrics against the account so every device can see them.
    ///
    /// Posts to `/user/lyrics`, not the service-key-gated submit path — this
    /// carries the user's own token. Returns whether it was accepted, so a
    /// bulk migration can retry a failure on the next launch rather than
    /// marking it done.
    func submitLyrics(title: String, artist: String, syncedLyrics: String) async -> Bool {
        guard token != nil else { return false }
        struct Body: Encodable {
            let title: String
            let artist: String
            let synced_lyrics: String
        }
        do {
            _ = try await makeRequest(
                "/user/lyrics", method: "POST",
                body: Body(title: title, artist: artist, synced_lyrics: syncedLyrics)
            )
            return true
        } catch {
            appWarn("submitLyrics(\(title)) failed: \(error.localizedDescription)", category: "network")
            return false
        }
    }
}
