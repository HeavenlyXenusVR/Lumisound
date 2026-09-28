import Foundation
import Combine

@MainActor
final class SleepTimerService: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var remainingSeconds: TimeInterval = 0
    @Published var selectedDuration: TimeInterval = 30 * 60
    /// Set to `true` for one tick when the timer expires; AudioPlayerManager observes this.
    @Published private(set) var didExpire = false
    /// `true` while the 60-second volume fade-out is in progress.
    @Published private(set) var isFading = false

    static let presets: [(label: String, seconds: TimeInterval)] = [
        ("5 min",  5  * 60),
        ("15 min", 15 * 60),
        ("30 min", 30 * 60),
        ("45 min", 45 * 60),
        ("1 hr",   60 * 60),
        ("90 min", 90 * 60),
    ]

    private var timer: Timer?
    private var fadeTimer: Timer?

    // Closure called to read/write the player's current volume so the service
    // stays decoupled from AudioPlayerManager's concrete type.
    var getVolume: (() -> Float)?
    var setVolume: ((Float) -> Void)?
    /// Closures to read/write the player's playback speed (`audioSettings.speed`).
    /// Used for the tempo "wind-down" that accompanies the volume fade — gently
    /// slowing playback toward a sleep-friendly tempo over the same window.
    var getRate: (() -> Float)?
    var setRate: ((Float) -> Void)?
    /// Called after the fade reaches zero — should pause/stop playback.
    var onExpire: (() -> Void)?

    // Mirrors AudioPlayerManager.shared/LibraryManager.shared — gives App
    // Intents (invoked directly by Siri/Shortcuts, with no SwiftUI environment
    // access) a way to reach the live sleep timer instance.
    static weak var shared: SleepTimerService?

    init() {
        Self.shared = self
    }

    func start(duration: TimeInterval? = nil) {
        let d = duration ?? selectedDuration
        selectedDuration = d
        remainingSeconds = d
        isActive = true
        didExpire = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Lets iOS batch this wake-up with others (battery).
        timer?.tolerance = (1) * 0.1
        appLog("SleepTimer: started for \(Int(d))s (\(formattedRemaining))", category: "general")
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        stopFade(restoreVolume: true)
        isActive = false
        remainingSeconds = 0
        didExpire = false
        appLog("SleepTimer: cancelled", category: "general")
    }

    var formattedRemaining: String {
        guard remainingSeconds > 0 else { return "0:00" }
        let total = Int(remainingSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func tick() {
        guard isActive, remainingSeconds > 0 else { return }
        remainingSeconds -= 1
        if remainingSeconds <= 0 {
            timer?.invalidate()
            timer = nil
            isActive = false
            appLog("SleepTimer: expired — beginning fade", category: "general")
            // Real device notification so the user learns the timer ended
            // even if the app isn't in the foreground — the fade itself is
            // silent otherwise, so without this the only visible sign is
            // music gradually getting quieter with no explanation.
            NotificationService.shared.notify(
                title: "Sleep Timer Ended",
                body: "Playback is fading out.",
                identifier: "sleep-timer-\(Date().timeIntervalSince1970)",
                topic: "sleep_timer_ending"
            )
            beginFade()
        }
    }

    // MARK: - Volume Fade

    static let fadeDurationPresets: [(label: String, seconds: TimeInterval)] = [
        ("10s",   10),
        ("30s",   30),
        ("1 min", 60),
        ("2 min", 120),
        ("5 min", 300),
    ]

    /// How long the volume/tempo fade-out takes once the timer hits zero.
    /// Persisted (unlike `selectedDuration`, which is session-only) since
    /// it's more a "set once" preference than something you'd change per nap.
    @Published var fadeDurationSeconds: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: "sleepTimer_fadeDuration")
        return saved > 0 ? saved : 60.0
    }() {
        didSet { UserDefaults.standard.set(fadeDurationSeconds, forKey: "sleepTimer_fadeDuration") }
    }

    private static let fadeStepInterval: Double = 0.5
    private var fadeStepCount: Int { max(1, Int(fadeDurationSeconds / Self.fadeStepInterval)) }

    /// Volume level captured just before the fade starts so it can be restored on cancel.
    private var volumeBeforeFade: Float = 1.0
    /// Playback speed captured just before the fade starts so it can be restored on cancel.
    private var rateBeforeFade: Float = 1.0
    /// Target playback speed for the tempo wind-down — 15% slower than whatever
    /// speed the user was already playing at, floored at 0.7x so very slow
    /// custom speeds don't get dragged into "barely audible" territory.
    private var fadeTargetRate: Float = 1.0
    /// Counts how many fade steps have fired.
    private var fadeStep: Int = 0

    private func beginFade() {
        guard !isFading else { return }
        volumeBeforeFade = getVolume?() ?? 1.0
        rateBeforeFade = getRate?() ?? 1.0
        fadeTargetRate = max(0.7, rateBeforeFade * 0.85)
        fadeStep = 0
        isFading = true

        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.fadeStepInterval,
            repeats: true
        ) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                self.applyFadeStep(timer: t)
            }
        }
    }

    private func applyFadeStep(timer t: Timer) {
        fadeStep += 1
        let progress = Float(fadeStep) / Float(fadeStepCount)
        let clipped = min(max(progress, 0), 1)
        let newVolume = volumeBeforeFade * (1.0 - clipped)
        setVolume?(newVolume)

        // Tempo wind-down: ease playback speed from its current value toward
        // `fadeTargetRate` in lockstep with the volume fade, so the music both
        // quiets down AND slows down as the sleep timer approaches zero.
        let newRate = rateBeforeFade + (fadeTargetRate - rateBeforeFade) * clipped
        setRate?(newRate)

        if fadeStep >= fadeStepCount {
            t.invalidate()
            fadeTimer = nil
            isFading = false
            setVolume?(0)
            onExpire?()
            // Restore volume so it isn't stuck at 0 when the user presses Play again —
            // but only if nothing else changed it meanwhile. The fade mutates the same
            // persisted `audioSettings.volume` the user's slider is bound to, so if they
            // nudged it back up mid-fade (current value no longer ~0), blindly restoring
            // `volumeBeforeFade` would silently discard that manual adjustment.
            if (getVolume?() ?? 0) < 0.01 {
                setVolume?(volumeBeforeFade)
            }
            // Same logic for speed: restore the pre-fade tempo unless the user
            // already changed it mid-fade (current value no longer near the target).
            if let currentRate = getRate?(), abs(currentRate - fadeTargetRate) < 0.01 {
                setRate?(rateBeforeFade)
            }
            didExpire = true
            appLog("SleepTimer: fade complete — playback stopped", category: "general")
            // Reset the flag after one run loop so observers don't re-trigger.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.didExpire = false
            }
        }
    }

    /// Stops an in-progress fade. If `restoreVolume` is true, returns volume to pre-fade level.
    private func stopFade(restoreVolume: Bool) {
        guard isFading else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        isFading = false
        if restoreVolume {
            setVolume?(volumeBeforeFade)
            setRate?(rateBeforeFade)
        }
    }
}
