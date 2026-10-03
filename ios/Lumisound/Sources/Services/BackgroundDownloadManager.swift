import Foundation
import UIKit

/// Wraps a download in a `UIBackgroundTaskIdentifier` so it can finish even if the
/// user switches apps briefly during a playlist "Download All" operation.
/// Provides ~30 seconds of extra background execution time per download.
enum BackgroundDownloadManager {

    /// `beginBackgroundTask`'s expiration handler fires on the main thread, while
    /// `run`'s `defer` resumes on whatever executor the awaited work completes on —
    /// so both can race to read/write the task identifier and end it. This box
    /// serializes those accesses behind a lock and a one-shot `ended` flag so
    /// `endBackgroundTask` is called exactly once, however the two interleave.
    /// (Calling it twice with the same identifier is documented as a fatal misuse.)
    fileprivate final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var taskID: UIBackgroundTaskIdentifier = .invalid
        private var ended = false

        func register(_ id: UIBackgroundTaskIdentifier) {
            lock.lock()
            let alreadyEnded = ended
            if !alreadyEnded { taskID = id }
            lock.unlock()
            // Expired before registration finished — end immediately rather than leak it.
            if alreadyEnded, id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
            }
        }

        func endIfNeeded() {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            let id = taskID
            taskID = .invalid
            lock.unlock()
            if id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
            }
        }

        var hasExpired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ended
        }
    }

    static func run<T>(
        named name: String,
        work: () async throws -> T
    ) async throws -> T {
        let box = TaskBox()
        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            box.endIfNeeded()
        }
        box.register(id)
        defer { box.endIfNeeded() }

        if box.hasExpired { throw CancellationError() }
        return try await work()
    }
}

/// A background-task assertion ended exactly once: by `end()`, or by iOS's
/// expiration handler if the work overruns, whichever comes first.
///
/// Several call sites passed an empty expiration handler (or none), on the
/// reasoning that there was nothing to cancel. But the handler is not for
/// cancelling work; it is the last chance to END the assertion, and iOS kills
/// an app that lets one expire unended. MetricKit recorded exactly that
/// (`backgroundTaskTimeout` exits) — the app being terminated in the background
/// whenever a push-triggered import or a gallery upload ran long.
final class BackgroundTaskToken: @unchecked Sendable {
    private let box = BackgroundDownloadManager.TaskBox()

    @MainActor
    init(name: String) {
        let box = self.box
        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            box.endIfNeeded()
        }
        box.register(id)
    }

    /// Whether iOS has already reclaimed the time (or `end()` was called).
    var hasExpired: Bool { box.hasExpired }

    func end() { box.endIfNeeded() }
}
