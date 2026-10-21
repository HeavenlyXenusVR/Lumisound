import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Sessions (active logins)

    /// Fetches this account's active sessions (one per signed-in device).
    func fetchSessions() async {
        guard isLoggedIn else { return }
        do {
            let data = try await makeRequest("/auth/sessions")
            struct Response: Decodable { let sessions: [AccountSession] }
            sessions = try JSONDecoder().decode(Response.self, from: data).sessions
        } catch let err as AccountError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Revokes a session by token ID. If it's the current device's session,
    /// also clears the local session (the user is effectively signed out).
    func revokeSession(tokenId: String) async {
        guard isLoggedIn else { return }
        do {
            _ = try await makeRequest("/auth/sessions/\(tokenId)", method: "DELETE")
            if sessions.first(where: { $0.tokenId == tokenId })?.isCurrent == true {
                clearSession()
                return
            }
            await fetchSessions()
        } catch let err as AccountError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Generates a long-lived (365-day) "RPC setup" token for local tools
    /// like the Discord Rich Presence bridge, so the user never has to put
    /// their account password in a desktop config file. The token shows up
    /// as a regular session ("Discord RPC Bridge") and can be revoked from
    /// Active Sessions.
    func generateRpcToken() async -> String? {
        guard isLoggedIn else { return nil }
        do {
            let data = try await makeRequest("/user/rpc-token", method: "POST")
            struct Response: Decodable { let token: String; let expires_at: String }
            return try JSONDecoder().decode(Response.self, from: data).token
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Fetches this account's registered Discord Rich Presence settings
    /// (Application client ID + optional art asset name). The local
    /// Rich Presence daemon reads this so users don't need to copy the
    /// client ID into a config file.
    func fetchDiscordRpcConfig() async -> DiscordRpcConfig? {
        guard isLoggedIn else { return nil }
        do {
            let data = try await makeRequest("/user/discord-rpc-config")
            return try JSONDecoder().decode(DiscordRpcConfig.self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Registers (or updates) Discord Rich Presence settings. `clientId: nil`
    /// (the common case now) means "use Lumisound's own shared Discord
    /// application" — nothing to register, the user just has to verify
    /// their Discord account and press Enable. Pass a real Discord
    /// Application ID only for a user who wants their own custom branding.
    func setDiscordRpcConfig(clientId: String? = nil, largeImage: String? = nil, smallImage: String? = nil, showButtons: Bool = true, enabled: Bool) async -> Bool {
        guard isLoggedIn else { return false }
        struct Body: Encodable {
            let discord_client_id: String?
            let large_image: String?
            let small_image: String?
            let show_buttons: Bool
            let enabled: Bool
        }
        do {
            _ = try await makeRequest("/user/discord-rpc-config", method: "PUT", body: Body(discord_client_id: clientId, large_image: largeImage, small_image: smallImage, show_buttons: showButtons, enabled: enabled))
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Removes the Discord Rich Presence registration entirely.
    func deleteDiscordRpcConfig() async -> Bool {
        guard isLoggedIn else { return false }
        do {
            _ = try await makeRequest("/user/discord-rpc-config", method: "DELETE")
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Fetches this account's personal YouTube Data API key status (masked).
    func fetchYoutubeApiKey() async -> YoutubeApiKeyConfig? {
        guard isLoggedIn else { return nil }
        do {
            let data = try await makeRequest("/user/youtube-api-key")
            return try JSONDecoder().decode(YoutubeApiKeyConfig.self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Saves (or replaces) this account's personal YouTube Data API key.
    /// Used by /api/resolve for full-playlist enumeration via playlistItems.list,
    /// and falls back to the server-wide key if unset.
    func setYoutubeApiKey(_ apiKey: String) async -> Bool {
        guard isLoggedIn else { return false }
        struct Body: Encodable { let api_key: String }
        do {
            _ = try await makeRequest("/user/youtube-api-key", method: "PUT", body: Body(api_key: apiKey))
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Result of validating a stored YouTube Data API key. `quotaUnitsUsedToday`
    /// is this SERVER's own running count of the cost of calls it has made with
    /// the key since the last Pacific-midnight reset — Google's Data API has no
    /// endpoint that reports a key's real remaining/used quota (that only exists
    /// in the Cloud Console, tied to the key's GCP project, not the key itself),
    /// so this is a floor on real usage, not an authoritative total: a key used
    /// anywhere else (another app, testing it directly) spends quota this count
    /// never sees. `nil` only on a network/other failure where the server
    /// couldn't be reached at all to ask.
    struct YouTubeKeyValidation {
        let status: String
        let quotaUnitsUsedToday: Int?
        let quotaCooldownActive: Bool
    }

    /// Validates this account's stored YouTube Data API key with a minimal
    /// server-side call. `status` is "valid", "invalid", "quota_exceeded", or
    /// "error" (network/other failure).
    func validateYouTubeAPIKey() async -> YouTubeKeyValidation {
        guard isLoggedIn else { return YouTubeKeyValidation(status: "error", quotaUnitsUsedToday: nil, quotaCooldownActive: false) }
        struct Response: Decodable {
            let status: String
            let quota_units_used_today: Int?
            let quota_cooldown_active: Bool?
        }
        do {
            let data = try await makeRequest("/youtube/validate-key", method: "POST")
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return YouTubeKeyValidation(
                status: decoded.status,
                quotaUnitsUsedToday: decoded.quota_units_used_today,
                quotaCooldownActive: decoded.quota_cooldown_active ?? false
            )
        } catch let err as AccountError {
            errorMessage = err.message
            return YouTubeKeyValidation(status: "error", quotaUnitsUsedToday: nil, quotaCooldownActive: false)
        } catch {
            errorMessage = error.localizedDescription
            return YouTubeKeyValidation(status: "error", quotaUnitsUsedToday: nil, quotaCooldownActive: false)
        }
    }

    /// Checks whether this account's stored YouTube Data API key shows signs
    /// of having been leaked/abused (invalid, referrer-restricted, or
    /// quota-exhausted shortly after setup).
    func checkYouTubeKeyExposure() async -> (exposed: Bool, detail: String) {
        guard isLoggedIn else { return (false, "") }
        struct Response: Decodable { let exposed: Bool; let detail: String }
        do {
            let data = try await makeRequest("/youtube/key-exposure-check")
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return (decoded.exposed, decoded.detail)
        } catch let err as AccountError {
            errorMessage = err.message
            return (false, "")
        } catch {
            errorMessage = error.localizedDescription
            return (false, "")
        }
    }

    /// Removes this account's personal YouTube Data API key.
    func deleteYoutubeApiKey() async -> Bool {
        guard isLoggedIn else { return false }
        do {
            _ = try await makeRequest("/user/youtube-api-key", method: "DELETE")
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Fetches this account's personal AcoustID API key status (masked).
    func fetchAcoustIDApiKey() async -> AcoustIDApiKeyConfig? {
        guard isLoggedIn else { return nil }
        do {
            let data = try await makeRequest("/user/acoustid-api-key")
            return try JSONDecoder().decode(AcoustIDApiKeyConfig.self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Saves (or replaces) this account's personal AcoustID API key.
    func setAcoustIDApiKey(_ apiKey: String) async -> Bool {
        guard isLoggedIn else { return false }
        struct Body: Encodable { let api_key: String }
        do {
            _ = try await makeRequest("/user/acoustid-api-key", method: "PUT", body: Body(api_key: apiKey))
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Removes this account's personal AcoustID API key.
    func deleteAcoustIDApiKey() async -> Bool {
        guard isLoggedIn else { return false }
        do {
            _ = try await makeRequest("/user/acoustid-api-key", method: "DELETE")
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
