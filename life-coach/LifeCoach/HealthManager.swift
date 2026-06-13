import Foundation
import HealthKit

/// Read-only HealthKit access so the coach can verify fitness commitments
/// (workouts, steps, sleep) instead of trusting self-reports.
enum HealthManager {
    private static let healthStore = HKHealthStore()

    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    static func requestPermission() async {
        guard isAvailable else { return }
        var readTypes: Set<HKObjectType> = [HKObjectType.workoutType()]
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
            readTypes.insert(steps)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            readTypes.insert(sleep)
        }
        try? await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Compact, prompt-ready summary of the last 7 days. Returns nil when
    /// HealthKit is unavailable or nothing could be read.
    static func summary() async -> String? {
        guard isAvailable else { return nil }
        var lines: [String] = []

        let workouts = await recentWorkouts(days: 7)
        if !workouts.isEmpty {
            lines.append("Workouts (last 7 days, from HealthKit): \(workouts.joined(separator: "; "))")
        } else {
            lines.append("Workouts (last 7 days, from HealthKit): none recorded.")
        }

        if let steps = await stepsToday() {
            lines.append("Steps today so far: \(Int(steps)).")
        }

        if let sleep = await sleepLastNight() {
            let hours = sleep / 3600
            lines.append(String(format: "Sleep last night: %.1f hours.", hours))
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Queries

    private static func recentWorkouts(days: Int) async -> [String] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let samples: [HKSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 20,
                sortDescriptors: [sort]
            ) { _, results, _ in
                continuation.resume(returning: results ?? [])
            }
            healthStore.execute(query)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            let minutes = Int(workout.duration / 60)
            let day = formatter.string(from: workout.startDate)
            return "\(day): \(Self.name(for: workout.workoutActivityType)) \(minutes) min"
        }
    }

    private static func stepsToday() async -> Double? {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                let value = statistics?.sumQuantity()?.doubleValue(for: .count())
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    /// Total asleep seconds between yesterday 6 PM and today noon.
    private static func sleepLastNight() async -> Double? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        guard let windowStart = calendar.date(byAdding: .hour, value: -6, to: todayStart),
              let windowEnd = calendar.date(byAdding: .hour, value: 12, to: todayStart) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd)

        let samples: [HKSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                continuation.resume(returning: results ?? [])
            }
            healthStore.execute(query)
        }

        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let total = samples
            .compactMap { $0 as? HKCategorySample }
            .filter { asleepValues.contains($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return total > 0 ? total : nil
    }

    private static func name(for activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycle"
        case .swimming: return "Swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .hiking: return "Hike"
        default: return "Workout"
        }
    }
}
