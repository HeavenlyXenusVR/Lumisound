import Foundation
import QuartzCore

// MARK: - TVAdvancedTelemetry
//
// Instrumentation for the things the existing telemetry could not see.
//
// The multi-second freeze on opening the library produced NO signal anywhere:
// every request succeeded, every screen reported loading normally, playback kept
// running, and the app never crashed. The logs said the app was healthy while it
// was visibly locked up, because nothing was measuring the one resource that had
// actually run out — main-thread time. Everything here exists to make that class
// of fault self-reporting rather than something a user has to notice and
// describe.
//
// Four probes:
//
//   1. `HitchMonitor`      — main-thread responsiveness, continuously.
//   2. `measure`           — wall-clock around a named span, main-thread or not.
//   3. `noteScreen`        — which screen is up and how long it was held.
//   4. `PlaybackSession`   — time to first audio, stalls, completion.
//
// All four are cheap enough to leave on permanently: the hitch monitor is one
// timer comparing two timestamps, and the rest only emit on transitions.

@MainActor
enum TVAdvancedTelemetry {

    // MARK: Main-thread hitches

    /// Detects main-thread stalls by scheduling a timer on the main run loop and
    /// measuring how late it actually fires.
    ///
    /// The main run loop can only service this timer when it is not busy, so
    /// lateness IS main-thread blockage — no sampling or instrumentation of the
    /// suspect code required, which matters because the cause is usually
    /// somewhere nobody thought to instrument. A sort in a view's getter, for
    /// instance.
    ///
    /// Reported in bands rather than as every measurement. A stalling app
    /// produces a continuous stream of these, and uploading all of them would
    /// both flood the log and add main-thread work to an already-blocked main
    /// thread — the monitor would become a cause of the thing it measures.
    final class HitchMonitor {
        static let shared = HitchMonitor()

        private var timer: Timer?
        private var lastFire = CACurrentMediaTime()
        private var worstThisWindow: Double = 0
        private var hitchCountThisWindow = 0
        private var windowStart = CACurrentMediaTime()

        /// How late a 0.1s timer must be before it counts as a hitch. Two frames
        /// at 60Hz is normal jitter; a quarter second is visible as a stutter.
        private let hitchThreshold: Double = 0.25
        /// How often to summarise. Long enough that a sustained stall reports
        /// once with a total rather than hundreds of times.
        private let reportWindow: Double = 30

        func start() {
            guard timer == nil else { return }
            lastFire = CACurrentMediaTime()
            windowStart = lastFire
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            // `.common` so the monitor keeps measuring while the focus engine is
            // driving a scroll — which is exactly when hitches are most visible
            // and when a default-mode timer would stop firing and see nothing.
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private func tick() {
            let now = CACurrentMediaTime()
            let late = (now - lastFire) - 0.1
            lastFire = now

            if late >= hitchThreshold {
                hitchCountThisWindow += 1
                worstThisWindow = max(worstThisWindow, late)
            }

            guard now - windowStart >= reportWindow else { return }
            defer {
                windowStart = now
                hitchCountThisWindow = 0
                worstThisWindow = 0
            }
            guard hitchCountThisWindow > 0 else { return }

            TVRemoteLogger.log(
                category: "performance",
                event: "main_thread_hitches",
                // Warn, not info: a hitch is the app failing to respond to the
                // remote. It should be findable without knowing to look for it.
                level: "warning",
                message: String(format: "%d hitches, worst %.0fms", hitchCountThisWindow, worstThisWindow * 1000),
                detail: [
                    "hitchCount": hitchCountThisWindow,
                    "worstMs": Int(worstThisWindow * 1000),
                    "windowSeconds": Int(reportWindow),
                    "screen": currentScreen ?? "unknown",
                ]
            )
        }
    }

    // MARK: Spans

    /// Times a block and logs how long it took. Use for work suspected of being
    /// expensive enough to matter — a sort, a decode, a grouping pass.
    ///
    /// Logs only past `thresholdMs` so routine fast paths cost nothing but the
    /// measurement itself; a span that is always fast should produce silence,
    /// not noise that hides the one time it was not.
    @discardableResult
    static func measure<T>(_ name: String,
                           thresholdMs: Int = 100,
                           detail: [String: Any] = [:],
                           _ work: () throws -> T) rethrows -> T {
        let started = CACurrentMediaTime()
        let result = try work()
        let elapsedMs = Int((CACurrentMediaTime() - started) * 1000)
        if elapsedMs >= thresholdMs {
            var payload = detail
            payload["span"] = name
            payload["elapsedMs"] = elapsedMs
            payload["screen"] = currentScreen ?? "unknown"
            TVRemoteLogger.log(
                category: "performance", event: "slow_span",
                level: elapsedMs >= 1000 ? "warning" : "info",
                message: "\(name) took \(elapsedMs)ms",
                detail: payload
            )
        }
        return result
    }

    // MARK: Screen dwell

    private(set) static var currentScreen: String?
    private static var screenEnteredAt: CFTimeInterval = CACurrentMediaTime()

    /// Records a screen change and how long the previous screen was held.
    ///
    /// Dwell time is the cheapest signal there is for whether a screen works: a
    /// tab people open and leave inside two seconds is one they did not find
    /// what they wanted on, and that is invisible in any per-request log.
    static func noteScreen(_ name: String) {
        let now = CACurrentMediaTime()
        if let previous = currentScreen {
            TVRemoteLogger.log(
                category: "navigation", event: "screen_exited",
                detail: ["screen": previous,
                         "dwellMs": Int((now - screenEnteredAt) * 1000),
                         "next": name]
            )
        }
        currentScreen = name
        screenEnteredAt = now
        TVRemoteLogger.log(category: "navigation", event: "screen_entered",
                           detail: ["screen": name])
    }

    // MARK: Playback sessions

    /// One track's playback, start to finish.
    ///
    /// Counts what a user actually experiences and the existing per-event logs
    /// could not express: how long the remote press took to produce sound, how
    /// many times it stopped again afterwards, and whether the track was
    /// finished or abandoned. A stall count is the difference between "streaming
    /// works" and "streaming works if you wait".
    final class PlaybackSession {
        private let trackID: String
        private let title: String
        private let isLocked: Bool
        private let startedAt: CFTimeInterval
        private var firstAudioAt: CFTimeInterval?
        private var stallCount = 0
        private var stalledSince: CFTimeInterval?
        private var totalStalledSeconds: Double = 0
        private var ended = false

        init(trackID: String, title: String, isLocked: Bool) {
            self.trackID = trackID
            self.title = title
            self.isLocked = isLocked
            self.startedAt = CACurrentMediaTime()
        }

        /// First moment audio is actually audible. Only the first call counts —
        /// later plays after a pause are not a new time-to-first-audio.
        func noteAudioStarted() {
            guard firstAudioAt == nil else { return }
            firstAudioAt = CACurrentMediaTime()
            let ms = Int((firstAudioAt! - startedAt) * 1000)
            TVRemoteLogger.log(
                category: "playback", event: "time_to_first_audio",
                level: ms > 8000 ? "warning" : "info",
                detail: ["trackID": trackID, "title": title,
                         "isLocked": isLocked, "elapsedMs": ms]
            )
        }

        func noteStallBegan() {
            guard stalledSince == nil else { return }
            stalledSince = CACurrentMediaTime()
            stallCount += 1
        }

        func noteStallEnded() {
            guard let since = stalledSince else { return }
            totalStalledSeconds += CACurrentMediaTime() - since
            stalledSince = nil
        }

        /// `completed` distinguishes a track that played out from one the user
        /// skipped — abandonment part-way through is the signal that something
        /// was wrong with it, and it looks identical to success without this.
        func end(completed: Bool, positionSeconds: Double, durationSeconds: Double) {
            guard !ended else { return }
            ended = true
            noteStallEnded()
            let wall = CACurrentMediaTime() - startedAt
            TVRemoteLogger.log(
                category: "playback", event: "playback_session_ended",
                detail: [
                    "trackID": trackID,
                    "title": title,
                    "isLocked": isLocked,
                    "completed": completed,
                    "everPlayed": firstAudioAt != nil,
                    "stallCount": stallCount,
                    "stalledMs": Int(totalStalledSeconds * 1000),
                    "sessionMs": Int(wall * 1000),
                    "positionSeconds": Int(positionSeconds),
                    "durationSeconds": Int(durationSeconds),
                    "fractionPlayed": durationSeconds > 0
                        ? Int((positionSeconds / durationSeconds) * 100) : 0,
                ]
            )
        }
    }
}
