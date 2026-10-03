import UIKit
import UserNotifications

/// Bridges UIKit's remote-notification callbacks into the app. SwiftUI's
/// `App` protocol has no equivalent hooks for APNs device-token delivery, so
/// a minimal `UIApplicationDelegate` is still required even though the rest
/// of the app is pure SwiftUI lifecycle. Actual registration is *triggered*
/// by `NotificationService.requestAuthorization()` (once local-notification
/// authorization is granted) — this class only forwards the OS's response
/// to the server via `AccountService`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await AccountService.shared?.registerPushToken(tokenHex) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on Simulator and on devices without a valid provisioning
        // profile/entitlement — not fatal, the app just keeps working with
        // in-app + server-inbox-poll notifications only.
        appWarn("APNs registration failed: \(error.localizedDescription)", category: "notifications")
    }

    /// Entry point for the "download_ready" silent/content-available push
    /// (see _send_push_best_effort's content_available param on the bridge)
    /// — lets a finished background download reach the library within
    /// seconds of completing, instead of waiting for the user to next open
    /// the app or for the next opportunistic BGAppRefreshTask run. Requires
    /// `remote-notification` in UIBackgroundModes (see Info.plist) to be
    /// invoked while the app isn't in the foreground. iOS still shows the
    /// alert banner itself; this only handles the accompanying background
    /// fetch. beginBackgroundTask covers the (typically few-second) fetch +
    /// import, since Apple's own budget for this callback is short and not
    /// guaranteed to cover a network round-trip on its own.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        switch userInfo["type"] as? String {
        case "download_ready":
            guard let streaming = StreamingService.shared else {
                completionHandler(.noData)
                return
            }
            // Ended by whichever comes first, the import or iOS reclaiming the
            // time — see `BackgroundTaskToken` for why an empty expiration
            // handler got the app killed.
            let bgTask = BackgroundTaskToken(name: "lumisound.download.reconcile")
            Task {
                let imported = await streaming.reconcilePendingDownloads()
                bgTask.end()
                completionHandler(imported > 0 ? .newData : .noData)
            }

        case "playback_transfer":
            handlePlaybackTransfer(userInfo: userInfo, application: application, completionHandler: completionHandler)

        default:
            completionHandler(.noData)
        }
    }

    /// Entry point for another of this account's devices sending "play this
    /// here" (see AccountService+PlaybackTransfer.swift / main.py's
    /// /user/playback/transfer). Resolves the track the same way any other
    /// "play a fetched StreamTrack" flow does (StreamingService.streamURL +
    /// toSong, same as e.g. DiscoverMixView's play(track:)) rather than
    /// inventing a separate playback path just for this.
    private func handlePlaybackTransfer(
        userInfo: [AnyHashable: Any],
        application: UIApplication,
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let data = userInfo["data"] as? [String: Any],
              let title = data["title"] as? String,
              let source = data["source"] as? String,
              let sourceID = data["source_id"] as? String, !sourceID.isEmpty,
              let streaming = StreamingService.shared,
              let player = AudioPlayerManager.shared else {
            completionHandler(.noData)
            return
        }
        let artist = data["artist"] as? String ?? ""
        let durationSeconds = (data["duration_seconds"] as? NSNumber)?.intValue ?? 0
        let positionSeconds = (data["position_seconds"] as? NSNumber)?.doubleValue ?? 0
        let isPlaying = data["is_playing"] as? Bool ?? true
        let track = StreamTrack(
            id: sourceID, title: title, artist: artist, durationSeconds: durationSeconds,
            thumbnailURL: data["thumbnail_url"] as? String ?? "", source: source,
            youtubeURL: data["track_url"] as? String ?? ""
        )

        let bgTask = BackgroundTaskToken(name: "lumisound.playback.transfer")
        Task {
            defer { bgTask.end() }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                await MainActor.run {
                    player.play(song: song, in: [song])
                    if positionSeconds > 0 {
                        player.seek(to: positionSeconds)
                    }
                    if !isPlaying {
                        player.pause()
                    }
                }
                completionHandler(.newData)
            } catch {
                appWarn("handlePlaybackTransfer: couldn't resolve stream URL: \(error.localizedDescription)", category: "notifications")
                completionHandler(.failed)
            }
        }
    }

    /// Shows the alert banner/sound even while the app is in the foreground —
    /// otherwise both local notifications and mirrored server pushes would
    /// silently do nothing while the user already has the app open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
        // The banner above is purely a system-level presentation — it doesn't
        // touch anything this app's own UI reads. Without this, AccountView's
        // unread-notification badge (an @Published on AccountService, so any
        // observing view updates live) only ever refreshed on that view's own
        // first-appear `.task`, so a push banner could visibly show while the
        // app was open with the in-app badge count staying stale until the
        // user navigated away and back — exactly the "needs a tab switch to
        // refresh" pattern. Best-effort/fire-and-forget: a failed refresh
        // here just means the badge catches up next time something else
        // triggers it, same as before this existed.
        Task { await AccountService.shared?.refreshUnreadNotificationCount() }
    }
}
