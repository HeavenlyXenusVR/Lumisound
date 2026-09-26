import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Notifications

    /// Fetches recent in-app notifications (achievements, subscriptions, etc.).
    func fetchNotifications(unreadOnly: Bool = false) async -> [AppNotification] {
        guard isLoggedIn else { return [] }
        do {
            let path = "/user/notifications" + (unreadOnly ? "?unread_only=true" : "")
            let data = try await makeRequest(path)
            return try JSONDecoder().decode([AppNotification].self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Refreshes `unreadNotificationCount` from the server. Call on app
    /// launch/foreground and — critically — right after a push arrives while
    /// the app is already foregrounded (see AppDelegate's `willPresent`),
    /// since that's the case a view's own `.task`-on-first-appear can't catch:
    /// the badge otherwise only updated once the user navigated away and
    /// back, even though the push banner itself displayed immediately.
    @discardableResult
    func refreshUnreadNotificationCount() async -> Int {
        guard isLoggedIn else {
            unreadNotificationCount = 0
            return 0
        }
        let count = await fetchNotifications(unreadOnly: true).count
        unreadNotificationCount = count
        return count
    }

    /// Marks a single notification as read.
    func markNotificationRead(id: String) async {
        guard isLoggedIn else { return }
        do {
            _ = try await makeRequest("/user/notifications/\(id)/read", method: "POST")
            await refreshUnreadNotificationCount()
        } catch {
            // Best-effort; the inbox will simply show it as unread next time.
        }
    }

    /// Marks all notifications as read.
    func markAllNotificationsRead() async {
        guard isLoggedIn else { return }
        do {
            _ = try await makeRequest("/user/notifications/read-all", method: "POST")
            unreadNotificationCount = 0
        } catch {
            // Best-effort.
        }
    }

    private static let deviceTokenKey = "apns_device_token_hex"
    private static let lastRegisteredTokenKey = "apns_last_registered_token"
    private static let lastRegisteredUserKey = "apns_last_registered_user_id"
    private static let lastRegisteredAtKey = "apns_last_registered_at"

    /// How long a successful registration is trusted before it is refreshed
    /// anyway. Bounded rather than permanent so a token the server lost — a
    /// restore, a row pruned, a failed write — is re-established within a day
    /// instead of never, which is the failure this dedupe could otherwise cause.
    private static let registrationTTL: TimeInterval = 24 * 60 * 60

    /// Registers this device's APNs token for push notifications. Also
    /// remembered locally (not tied to a session) so `logout()` can
    /// unregister it without needing a fresh callback from the OS.
    ///
    /// Skips the network call when this exact token has already been registered
    /// for this exact user within `registrationTTL`.
    ///
    /// Without that check this posted on **every foreground return**:
    /// `NotificationService` re-checks OS authorization on
    /// `didBecomeActiveNotification` and calls `registerForRemoteNotifications()`
    /// whenever authorized, the OS answers with the same device token, and
    /// `AppDelegate` funnels that straight back here. Re-registering with the OS
    /// genuinely is a free no-op, but the resulting POST is not — field telemetry
    /// recorded 29 `push_token_registered` events in six hours from a single
    /// device. That is a request per app switch, and enough repeated noise to
    /// bury real events in the log it shares.
    func registerPushToken(_ deviceToken: String) async {
        UserDefaults.standard.set(deviceToken, forKey: Self.deviceTokenKey)
        guard isLoggedIn else { return }

        let defaults = UserDefaults.standard
        let currentUserID = currentUser?.id
        // Keyed on the user too, so switching accounts on one device always
        // re-registers — otherwise the new account would never receive pushes
        // while the old account's registration looked current.
        if defaults.string(forKey: Self.lastRegisteredTokenKey) == deviceToken,
           defaults.string(forKey: Self.lastRegisteredUserKey) == currentUserID,
           currentUserID != nil {
            let registeredAt = defaults.double(forKey: Self.lastRegisteredAtKey)
            if registeredAt > 0, Date().timeIntervalSince1970 - registeredAt < Self.registrationTTL {
                return
            }
        }

        struct Body: Encodable { let device_token: String; let platform: String; let device_name: String }
        do {
            _ = try await makeRequest(
                "/user/push-token", method: "POST",
                body: Body(device_token: deviceToken, platform: "ios", device_name: UIDevice.current.name)
            )
            // Recorded only on success, so a failed attempt retries rather than
            // being suppressed for a day by its own failure.
            defaults.set(deviceToken, forKey: Self.lastRegisteredTokenKey)
            defaults.set(currentUserID, forKey: Self.lastRegisteredUserKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastRegisteredAtKey)
        } catch {
            // Best-effort; will retry on next launch.
        }
    }

    /// Unregisters this device's APNs token (e.g. on logout).
    func unregisterPushToken(_ deviceToken: String) async {
        // Cleared unconditionally and FIRST, so the dedupe in
        // `registerPushToken` cannot suppress the re-registration that follows a
        // logout/login cycle. Doing this only on a successful DELETE would leave
        // a device that failed to unregister also unable to re-register.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.lastRegisteredTokenKey)
        defaults.removeObject(forKey: Self.lastRegisteredUserKey)
        defaults.removeObject(forKey: Self.lastRegisteredAtKey)

        guard isLoggedIn else { return }
        do {
            _ = try await makeRequest("/user/push-token/\(deviceToken)", method: "DELETE")
        } catch {
            // Best-effort.
        }
    }

    /// Unregisters whatever APNs token this device last registered, if any —
    /// so a logged-out device stops receiving another account's pushes.
    func unregisterCurrentDeviceToken() async {
        guard let token = UserDefaults.standard.string(forKey: Self.deviceTokenKey) else { return }
        await unregisterPushToken(token)
    }

    /// Re-sends this device's already-obtained APNs token to the server, if
    /// it has one cached. `registerPushToken(_:)` above intentionally skips
    /// its network call while logged out — which is the common case, since
    /// APNs registration typically completes (and caches the token here)
    /// before the user has signed in on a fresh install. Without this, that
    /// token was never actually reaching the server even after the user
    /// later logged in, silently leaving that device unable to receive real
    /// pushes until its token happened to change. `NotificationService`
    /// calls this whenever `isLoggedIn` flips to `true`; it's a harmless
    /// no-op otherwise (nothing logged in, or no token cached yet).
    func resendStoredPushTokenIfNeeded() async {
        guard isLoggedIn, let token = UserDefaults.standard.string(forKey: Self.deviceTokenKey) else { return }
        await registerPushToken(token)
    }
}
