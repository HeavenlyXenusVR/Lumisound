import Darwin
import Foundation
import MetricKit

// MARK: - PerformanceMonitorService

/// Always-on CPU/GPU resource-usage logging — no settings toggle, starts
/// automatically at launch. Every `AppLogger` entry already auto-attaches
/// `DeviceInfo.modelIdentifier`/`.osVersion` (see `AppLogger.LogEntry`), so
/// logging through `appLog(..., category: "performance")` gets "categorized
/// by device and iOS number" for free — no extra plumbing needed here.
///
/// Two independent sources, since no single public iOS API covers both CPU
/// and GPU in real time:
///  1. `CPUSampler` — coarse system-wide CPU load every 60s via Darwin's
///     `host_cpu_load_info`, the same counters `top`/Activity Monitor read.
///  2. `MetricSubscriber` — Apple's own MetricKit daily aggregate, which is
///     the ONLY public API surface exposing GPU usage on iOS at all; there
///     is no real-time per-frame GPU-utilization query available to apps.
enum PerformanceMonitorService {
    /// Call once from `LumisoundApp.init()`, alongside the other `.register()`
    /// calls — must be set up before/at launch so MetricKit doesn't miss the
    /// registration window and so CPU sampling covers the whole session.
    static func start() {
        CPUSampler.shared.start()
        MXMetricManager.shared.add(MetricSubscriber.shared)
    }
}

// MARK: - CPUSampler (periodic system CPU load)

/// Samples system-wide CPU load (not just this process) every 60s via
/// `host_cpu_load_info` — cumulative tick counts since boot, diffed between
/// two samples to get a per-interval percentage, same technique `top` uses.
private final class CPUSampler {
    static let shared = CPUSampler()

    private var timer: Timer?
    private var lastTicks: host_cpu_load_info_data_t?

    func start() {
        guard timer == nil else { return }
        sample() // seeds `lastTicks` immediately rather than waiting 60s for a first reading
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        guard let ticks = Self.currentTicks() else { return }
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return }

        // Double subtraction (never traps on underflow) rather than raw
        // UInt32 arithmetic — the tick counters are monotonic in practice,
        // but this stays safe even across the rare edge case (counter
        // wraparound after a very long uptime) instead of crashing.
        let userDelta = Double(ticks.cpu_ticks.0) - Double(last.cpu_ticks.0)
        let systemDelta = Double(ticks.cpu_ticks.1) - Double(last.cpu_ticks.1)
        let idleDelta = Double(ticks.cpu_ticks.2) - Double(last.cpu_ticks.2)
        let niceDelta = Double(ticks.cpu_ticks.3) - Double(last.cpu_ticks.3)
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return }

        let userPct = userDelta / total * 100
        let systemPct = systemDelta / total * 100
        let idlePct = idleDelta / total * 100

        appLog(
            String(format: "CPU load — user %.1f%% system %.1f%% idle %.1f%%", userPct, systemPct, idlePct),
            category: "performance",
            extra: [
                "cpuUserPct": String(format: "%.1f", userPct),
                "cpuSystemPct": String(format: "%.1f", systemPct),
                "cpuIdlePct": String(format: "%.1f", idlePct),
                "thermalState": ProcessInfo.processInfo.thermalState.lumisoundDescription,
            ]
        )
    }

    private static func currentTicks() -> host_cpu_load_info_data_t? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info
    }
}

private extension ProcessInfo.ThermalState {
    var lumisoundDescription: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - MetricSubscriber (Apple's own daily CPU/GPU aggregate)

/// Receives `MXMetricPayload`s — delivered by the OS roughly once per day,
/// each summarizing the previous ~24h window's cumulative CPU time, GPU
/// time, and thermal-state exposure for this app specifically. This is
/// Apple's intended mechanism for exactly this kind of field performance
/// monitoring; there's no faster or more granular public API for GPU usage
/// on iOS, so a daily rollup (rather than a live percentage) is the honest
/// ceiling of what's queryable here.
private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricSubscriber()

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            var extra: [String: String] = [
                "periodStart": Self.iso(payload.timeStampBegin),
                "periodEnd": Self.iso(payload.timeStampEnd),
            ]
            if let cpu = payload.cpuMetrics?.cumulativeCPUTime {
                extra["cumulativeCPUTimeSeconds"] = String(format: "%.1f", cpu.converted(to: .seconds).value)
            }
            if let gpu = payload.gpuMetrics?.cumulativeGPUTime {
                extra["cumulativeGPUTimeSeconds"] = String(format: "%.1f", gpu.converted(to: .seconds).value)
            }
            appLog("MetricKit daily CPU/GPU report", category: "performance", extra: extra)

            // WHY the app stopped running, which nothing here reported before.
            //
            // Field logs show real unclean shutdowns — the app's own breadcrumb
            // trail records 15 on the current build across 6 accounts, always
            // ending mid-playback or just after opening the Library — but the
            // breadcrumbs only say what happened BEFORE, never the reason. That
            // left "a few crashes" unanswerable: memory peaks top out near 400MB
            // with no correlation to which accounts die most (one account peaked
            // at 396MB with a single shutdown, another at 362MB with dozens), so
            // guessing from resource usage was not going to settle it either.
            //
            // `applicationExitMetrics` is the authoritative answer and costs
            // nothing extra: the OS already computes it and it distinguishes the
            // possibilities that need completely different fixes — a memory kill,
            // a watchdog timeout, a bad memory access, a CPU limit while
            // backgrounded, or an ordinary exit that was never a crash at all.
            reportExitMetrics(payload)
        }
    }

    /// Reports the OS's own breakdown of how this app's recent sessions ended.
    ///
    /// Foreground and background are kept apart deliberately: a background memory
    /// kill is routine for an audio app and means one thing, while the same kill in
    /// the foreground means the app is genuinely using too much. Zero counts are
    /// dropped so the report carries only what actually happened.
    private func reportExitMetrics(_ payload: MXMetricPayload) {
        guard let exits = payload.applicationExitMetrics else { return }

        var detail: [String: Any] = [
            "periodStart": Self.iso(payload.timeStampBegin),
            "periodEnd": Self.iso(payload.timeStampEnd),
        ]
        func add(_ prefix: String, _ counts: [(String, Int)]) {
            for (name, value) in counts where value > 0 {
                detail["\(prefix)_\(name)"] = value
            }
        }
        let fg = exits.foregroundExitData
        add("fg", [
            ("normal", fg.cumulativeNormalAppExitCount),
            ("memoryLimit", fg.cumulativeMemoryResourceLimitExitCount),
            ("badAccess", fg.cumulativeBadAccessExitCount),
            ("abnormal", fg.cumulativeAbnormalExitCount),
            ("illegalInstruction", fg.cumulativeIllegalInstructionExitCount),
            ("watchdog", fg.cumulativeAppWatchdogExitCount),
        ])
        let bg = exits.backgroundExitData
        add("bg", [
            ("normal", bg.cumulativeNormalAppExitCount),
            ("memoryLimit", bg.cumulativeMemoryResourceLimitExitCount),
            ("cpuLimit", bg.cumulativeCPUResourceLimitExitCount),
            ("badAccess", bg.cumulativeBadAccessExitCount),
            ("abnormal", bg.cumulativeAbnormalExitCount),
            ("illegalInstruction", bg.cumulativeIllegalInstructionExitCount),
            ("watchdog", bg.cumulativeAppWatchdogExitCount),
            ("suspendedWithLockedFile", bg.cumulativeSuspendedWithLockedFileExitCount),
            ("backgroundTaskTimeout", bg.cumulativeBackgroundTaskAssertionTimeoutExitCount),
        ])

        // An abnormal count of zero everywhere is the good case and still worth
        // recording: it is what distinguishes "no crashes happened" from "nothing
        // reported", which the unclean-shutdown breadcrumbs cannot tell apart.
        let crashy = detail.keys.contains { key in
            key.hasSuffix("memoryLimit") || key.hasSuffix("badAccess") || key.hasSuffix("abnormal")
                || key.hasSuffix("illegalInstruction") || key.hasSuffix("watchdog")
                || key.hasSuffix("cpuLimit") || key.hasSuffix("backgroundTaskTimeout")
        }
        RemoteLogger.log(
            category: "diagnostics", event: "app_exit_metrics",
            level: crashy ? "warning" : "info",
            message: crashy ? "abnormal exits reported" : "no abnormal exits",
            detail: detail
        )
    }

    // MARK: Crash / hang diagnostics

    /// Delivered by the OS after a crash, an unresponsive stretch, or a
    /// disk-write exception — usually on the next launch.
    ///
    /// This callback simply was not implemented, which is why crashes had no
    /// recorded cause at all. `MXMetricPayload` above covers CPU and GPU; the
    /// diagnostic payload is the separate one carrying the exception type, the
    /// signal, the OS's termination reason, and the call stack that produced it.
    /// Without it the only evidence of a crash was the app noticing, on its next
    /// launch, that the previous session had not shut down cleanly — which says
    /// nothing whatsoever about why.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var detail: [String: Any] = [
                    "appVersion": crash.metaData.applicationBuildVersion,
                    "osVersion": crash.metaData.osVersion,
                    "deviceType": crash.metaData.deviceType,
                ]
                if let type = crash.exceptionType { detail["exceptionType"] = type.intValue }
                if let code = crash.exceptionCode { detail["exceptionCode"] = code.intValue }
                if let signal = crash.signal { detail["signal"] = signal.intValue }
                if let reason = crash.terminationReason { detail["terminationReason"] = reason }
                if let vmRegion = crash.virtualMemoryRegionInfo { detail["vmRegion"] = String(vmRegion.prefix(200)) }
                // The full tree is large and mostly addresses; the leading frames
                // are what identify a crash site, and keeping this bounded means a
                // crash report can never be too big to actually get uploaded.
                if let json = try? crash.callStackTree.jsonRepresentation(),
                   let text = String(data: json, encoding: .utf8) {
                    detail["callStackPrefix"] = String(text.prefix(1800))
                }
                RemoteLogger.logError(
                    category: "diagnostics", event: "crash_diagnostic",
                    message: crash.terminationReason ?? "crash reported by MetricKit",
                    detail: detail
                )
            }

            // A hang is not a crash, but it is what the OS kills an app FOR — a
            // watchdog exit in the metrics above and a hang here are two views of
            // the same event, so both are needed to tell them apart.
            for hang in payload.hangDiagnostics ?? [] {
                RemoteLogger.log(
                    category: "diagnostics", event: "hang_diagnostic", level: "warning",
                    message: "main thread unresponsive for \(String(format: "%.1f", hang.hangDuration.converted(to: .seconds).value))s",
                    detail: [
                        "hangSeconds": hang.hangDuration.converted(to: .seconds).value,
                        "appVersion": hang.metaData.applicationBuildVersion,
                        "osVersion": hang.metaData.osVersion,
                    ]
                )
            }

            for exception in payload.diskWriteExceptionDiagnostics ?? [] {
                RemoteLogger.log(
                    category: "diagnostics", event: "disk_write_exception", level: "warning",
                    message: "excessive disk writes",
                    detail: ["writesCausedMB": exception.totalWritesCaused.converted(to: .megabytes).value]
                )
            }
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
