import Foundation
import HealthKit

/// Learns roughly how long it actually takes you to fall asleep from
/// HealthKit sleep-analysis data (Apple Watch sleep tracking, or any app
/// that writes sleep stages), and suggests that as the Sleep Timer's
/// duration instead of a fixed guess. Opt-in — see HearingHealthService's
/// doc comment for the same `com.apple.developer.healthkit` entitlement/
/// `NSHealthShareUsageDescription` this reuses, nothing new to add there.
@MainActor
final class AdaptiveSleepTimerService: ObservableObject {
    static let shared = AdaptiveSleepTimerService()

    @Published private(set) var isAuthorized = false
    /// nil until learned (or if there's not enough sleep data yet).
    @Published private(set) var suggestedMinutes: Double?

    private let store = HKHealthStore()
    private let sleepType = HKCategoryType(.sleepAnalysis)

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private init() {}

    func requestAuthorization() async {
        guard isHealthDataAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType])
            isAuthorized = true
            await learn()
        } catch {
            appWarn("AdaptiveSleepTimerService: authorization failed: \(error.localizedDescription)", category: "health")
        }
    }

    /// Averages time-to-fall-asleep (first "in bed" sample to the next
    /// "asleep" sample of any stage) across the last 14 days of sleep data,
    /// clamped to a sane 5...60 minute range — a learned value miles
    /// outside that is more likely bad data (a nap logged oddly, a gap in
    /// tracking) than a real answer worth acting on.
    func learn() async {
        guard isAuthorized, isHealthDataAvailable else { return }
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -14, to: Date()) else { return }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit,
                                       sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        guard !samples.isEmpty else { return }

        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]

        var deltas: [TimeInterval] = []
        var pendingInBedStart: Date?
        for sample in samples {
            if sample.value == HKCategoryValueSleepAnalysis.inBed.rawValue {
                pendingInBedStart = sample.startDate
            } else if asleepValues.contains(sample.value), let inBedStart = pendingInBedStart {
                let delta = sample.startDate.timeIntervalSince(inBedStart)
                if delta > 0, delta < 3 * 3600 {  // discard anything implausible (bad/overlapping data)
                    deltas.append(delta)
                }
                pendingInBedStart = nil
            }
        }
        guard !deltas.isEmpty else { return }

        let averageMinutes = (deltas.reduce(0, +) / Double(deltas.count)) / 60
        suggestedMinutes = min(60, max(5, averageMinutes))
    }
}
