import Foundation
import HealthKit

/// Reads Apple's own Headphone Audio Levels data (HealthKit's
/// `headphoneAudioExposure` quantity type, populated system-wide by iOS's
/// own Hearing Health feature) and correlates it with Lumisound's own
/// Volume Boost usage.
///
/// Deliberately read-only, and deliberately NOT a from-scratch exposure
/// estimator: a third-party app can only ever infer loudness from digital
/// signal level + the system volume slider, which is far less accurate
/// than iOS's own on-device, hardware-calibrated measurement. Reinventing
/// that would be both more engineering effort and a worse result. What
/// Apple's system feature can't do is tie a loud day back to what Lumisound
/// itself was doing at the time — that's the one thing this adds.
@MainActor
final class HearingHealthService: ObservableObject {
    static let shared = HearingHealthService()

    @Published private(set) var isAuthorized = false
    @Published private(set) var dailyExposure: [DailyExposure] = []  // last 30 days, oldest first
    @Published private(set) var isLoading = false

    struct DailyExposure: Identifiable {
        var id: Date { day }
        let day: Date
        let averageDecibels: Double?  // nil = no headphone exposure data that day
        let volumeBoostWasActive: Bool
    }

    private let store = HKHealthStore()
    private let exposureType = HKQuantityType(.headphoneAudioExposure)

    private static let boostDaysKey = "hearing_health_boost_active_days_v1"

    /// WHO/NIOSH-style guidance — the same rough threshold Apple's own
    /// Health app treats as where sustained-exposure risk starts climbing.
    static let elevatedExposureThresholdDB: Double = 80.0

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private init() {}

    func requestAuthorization() async {
        guard isHealthDataAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: [exposureType])
            // HealthKit deliberately never reveals whether read access was
            // actually granted (privacy) — `requestAuthorization` not
            // throwing is the only signal available. Treat it as
            // authorized and let an empty `dailyExposure` after `refresh()`
            // speak for itself if the user declined.
            isAuthorized = true
            await refresh()
        } catch {
            appWarn("HearingHealthService: authorization request failed: \(error.localizedDescription)", category: "health")
        }
    }

    /// Called from `AudioPlayerManager+ApplySettings.applyOutputGain()`
    /// whenever Volume Boost (>100%) is actually in effect during playback
    /// — cheap, UserDefaults-backed daily marker, so there's something
    /// Lumisound-specific to correlate exposure against without a full
    /// interval-logging system. Idempotent per day.
    static func markBoostActiveToday() {
        let key = dayKey(for: Date())
        var days = Set(UserDefaults.standard.stringArray(forKey: boostDaysKey) ?? [])
        guard !days.contains(key) else { return }
        days.insert(key)
        let cutoff = dayKey(for: Date().addingTimeInterval(-30 * 86400))
        days = Set(days.filter { $0 >= cutoff })
        UserDefaults.standard.set(Array(days), forKey: boostDaysKey)
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    func refresh() async {
        guard isAuthorized, isHealthDataAvailable else { return }
        isLoading = true
        defer { isLoading = false }

        let calendar = Calendar.current
        let now = Date()
        guard let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) else { return }
        let boostDays = Set(UserDefaults.standard.stringArray(forKey: Self.boostDaysKey) ?? [])

        let query = HKStatisticsCollectionQuery(
            quantityType: exposureType,
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate),
            options: .discreteAverage,
            anchorDate: calendar.startOfDay(for: start),
            intervalComponents: DateComponents(day: 1)
        )

        let results: [DailyExposure] = await withCheckedContinuation { continuation in
            query.initialResultsHandler = { _, collection, _ in
                var days: [DailyExposure] = []
                collection?.enumerateStatistics(from: start, to: now) { stats, _ in
                    let avg = stats.averageQuantity()?.doubleValue(for: .decibelAWeightedSoundPressureLevel())
                    days.append(DailyExposure(
                        day: stats.startDate,
                        averageDecibels: avg,
                        volumeBoostWasActive: boostDays.contains(Self.dayKey(for: stats.startDate))
                    ))
                }
                continuation.resume(returning: days)
            }
            store.execute(query)
        }
        dailyExposure = results
    }

    var daysOverThresholdThisWeek: Int {
        dailyExposure.suffix(7).filter { ($0.averageDecibels ?? 0) >= Self.elevatedExposureThresholdDB }.count
    }

    /// nil when there's nothing worth saying (no loud days, or loud days
    /// with no boost correlation) — callers should hide the row entirely
    /// rather than show an empty/zero state for this one.
    var boostCorrelationSummary: String? {
        let loudDays = dailyExposure.suffix(7).filter { ($0.averageDecibels ?? 0) >= Self.elevatedExposureThresholdDB }
        guard !loudDays.isEmpty else { return nil }
        let loudAndBoosted = loudDays.filter(\.volumeBoostWasActive).count
        guard loudAndBoosted > 0 else { return nil }
        let pct = Int((Double(loudAndBoosted) / Double(loudDays.count) * 100).rounded())
        return "Volume Boost was active on \(pct)% of your loud-listening days this week."
    }
}
