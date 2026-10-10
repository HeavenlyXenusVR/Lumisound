import CoreMotion
import UIKit

/// Shake the phone to skip; cover the proximity sensor (top of the phone,
/// same sensor a phone call uses to blank the screen against your cheek)
/// to pause. Both opt-in, OFF by default — accelerometer polling has a
/// real (if small) battery cost, and an unwanted skip/pause from an
/// accidental bump or pocket-cover would be an actively bad default, not
/// just an unused feature.
///
/// Shake detection uses `CMMotionManager` accelerometer polling (reuses the
/// existing `NSMotionUsageDescription` already granted for Spatial Audio's
/// head tracking — no new permission string needed) rather than the
/// system `UIResponder.motionEnded(_:with:)` shake event, which needs a
/// window/responder-chain override this SwiftUI-lifecycle app doesn't
/// otherwise have a clean place to add.
@MainActor
final class PhysicalGesturesService: ObservableObject {
    static weak var shared: PhysicalGesturesService?

    private static let enabledKey = "physicalGestures.enabled"
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: PhysicalGesturesService.enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    weak var player: AudioPlayerManager?

    private let motionManager = CMMotionManager()
    private var lastAcceleration: CMAcceleration?
    private var lastShakeAt: Date = .distantPast
    private var isRunning = false

    /// Sum-of-axis-deltas magnitude past this, between consecutive ~0.1s
    /// samples, reads as a real shake rather than normal handling/walking
    /// — picked generously above ordinary pocket/hand jostle on purpose:
    /// false positives (skipping a track because the phone got bumped)
    /// are worse than occasionally missing a deliberate shake.
    private static let shakeThreshold = 2.2
    private static let shakeCooldown: TimeInterval = 1.5

    init() {
        Self.shared = self
    }

    func start() {
        guard isEnabled, !isRunning else { return }
        isRunning = true

        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.1
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.handleAccelerometer(data.acceleration)
            }
        }

        UIDevice.current.isProximityMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(proximityChanged),
            name: UIDevice.proximityStateDidChangeNotification, object: nil
        )
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motionManager.stopAccelerometerUpdates()
        lastAcceleration = nil
        UIDevice.current.isProximityMonitoringEnabled = false
        NotificationCenter.default.removeObserver(self, name: UIDevice.proximityStateDidChangeNotification, object: nil)
    }

    private func handleAccelerometer(_ acceleration: CMAcceleration) {
        defer { lastAcceleration = acceleration }
        guard let last = lastAcceleration else { return }
        let delta = abs(acceleration.x - last.x) + abs(acceleration.y - last.y) + abs(acceleration.z - last.z)
        guard delta > Self.shakeThreshold else { return }
        guard Date().timeIntervalSince(lastShakeAt) > Self.shakeCooldown else { return }
        lastShakeAt = Date()
        player?.skipToNext()
    }

    @objc private func proximityChanged() {
        guard UIDevice.current.proximityState, player?.isPlaying == true else { return }
        player?.pause()
    }
}
