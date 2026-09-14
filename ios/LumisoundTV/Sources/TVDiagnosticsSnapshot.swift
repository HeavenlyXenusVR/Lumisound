import AVFoundation
import Foundation
import UIKit

// MARK: - TVDiagnosticsSnapshot
//
// tvOS port of the iOS app's DiagnosticsSnapshotService: a periodic,
// structured readout of what a live session actually looks like, sent to the
// bridge's event log.
//
// This exists because tvOS is the hardest surface in this project to debug —
// there is no Mac in this dev environment, no device console, and unlike the
// phone the Apple TV isn't usually sitting next to whoever is investigating.
// Every tvOS question so far ("why is there no artwork", "why won't a locked
// track stream") had to be answered by inference from the SERVER side alone,
// because the app reported almost nothing about itself. Worse, what it did
// report was indistinguishable from the iPhone's: the bridge tags every
// /api/log-event row source="ios_client" and the table has no device column,
// so "show me what the Apple TV did" was not a query anyone could write. That
// is fixed at the source now — TVRemoteLogger stamps platform/app version/
// model onto every event — and this adds the standing state to go with it.
//
// Deliberately configuration and counts only: no titles, no queue contents,
// no anything that would turn this into a record of what someone watched.
@MainActor
enum TVDiagnosticsSnapshot {
    /// Matches the iOS service's interval so both platforms' timelines line
    /// up when read side by side.
    private static let interval: TimeInterval = 5 * 60
    private static var timer: Timer?

    /// When a snapshot was last actually delivered. tvOS apps are commonly
    /// left running for hours and then backgrounded for days, so a tick that
    /// lands while suspended must not be silently lost — see `noteDidBecomeActive`.
    private static var lastSentAt: Date?

    static func start() {
        guard timer == nil else { return }
        send(reason: "app_launch")
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { send(reason: "periodic") }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Takes the snapshot that came due while the app was suspended. The iOS
    /// port of this service shipped without it and, across its first three
    /// real sessions, logged only launch-time snapshots and not a single
    /// periodic one — the timer doesn't tick while suspended. Same trap here.
    static func noteDidBecomeActive() {
        guard timer != nil else { return }
        if let last = lastSentAt, Date().timeIntervalSince(last) < interval { return }
        send(reason: "foreground")
    }

    private static func send(reason: String) {
        lastSentAt = Date()
        TVRemoteLogger.log(
            category: "diagnostics",
            event: "snapshot",
            message: reason,
            detail: [
                "device": deviceSnapshot(),
                "account": accountSnapshot(),
                "playback": playbackSnapshot(),
            ]
        )
    }

    private static func deviceSnapshot() -> [String: Any] {
        [
            "model": TVDeviceInfo.modelIdentifier,
            "tvosVersion": TVDeviceInfo.osVersion,
            "appVersion": TVDeviceInfo.appVersion,
            "thermalState": String(describing: ProcessInfo.processInfo.thermalState),
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "uptimeSeconds": Int(ProcessInfo.processInfo.systemUptime),
            // Which bridge this box is actually talking to. A tvOS install
            // pointed at a stale or wrong base URL behaves exactly like a
            // broken backend, and nothing else in the log would say so.
            "bridgeHost": URL(string: TVBridgeClient.shared.baseURL)?.host ?? "unset",
        ]
    }

    private static func accountSnapshot() -> [String: Any] {
        let account = TVAccount.shared
        return [
            // Whether a token exists at all is the single most useful auth
            // signal here: every authenticated tvOS request (cloud library
            // listing, locked-track fetch, artwork) fails identically without
            // one, and the user-visible result is just "nothing loads".
            "hasToken": account.token != nil,
            "isLoggedIn": account.isLoggedIn,
        ]
    }

    private static func playbackSnapshot() -> [String: Any] {
        let model = TVPlayerModel.shared
        return [
            "hasCurrentTrack": model.current != nil,
            "isPlaying": model.isPlaying,
            "isBuffering": model.isBuffering,
            "queueCount": model.queue.count,
            "positionSeconds": Int(model.position),
            "durationSeconds": Int(model.duration),
            "isShuffled": model.isShuffled,
            "repeatMode": String(describing: model.repeatMode),
            // The distinguishing fact for this platform: a locked cloud track
            // has to be downloaded and unlocked in full before AVFoundation
            // can open it, so "current track is locked" changes what a
            // playback failure even means.
            "currentIsLocked": model.current?.isLocked ?? false,
            "currentExt": model.current?.ext ?? "",
        ]
    }

}
