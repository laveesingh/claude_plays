import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var state: AppState {
        didSet { save() }
    }

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("lifecoach-state.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(AppState.self, from: data) {
            state = decoded
        } else {
            state = AppState()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Day helpers

    static func key(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    var todayKey: String { Self.key(for: Date()) }

    var today: DayLog {
        state.days[todayKey] ?? DayLog(dateKey: todayKey)
    }

    func log(for date: Date) -> DayLog? {
        state.days[Self.key(for: date)]
    }

    // MARK: - Time blocks

    /// Replaces today's schedule. Resolved statuses are preserved for blocks the
    /// coach kept with the same title.
    func setTodayBlocks(_ blocks: [TimeBlock]) {
        var log = today
        var updated = blocks
        for (index, block) in updated.enumerated() {
            if let existing = log.blocks.first(where: {
                $0.title.lowercased() == block.title.lowercased() && $0.status != .planned
            }) {
                updated[index].status = existing.status
            }
        }
        log.blocks = updated.sorted { $0.startMinutes < $1.startMinutes }
        state.days[todayKey] = log
    }

    func setBlockStatus(blockID: UUID, dateKey: String, status: BlockStatus) {
        guard var log = state.days[dateKey] ?? (dateKey == todayKey ? today : nil),
              let index = log.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        log.blocks[index].status = status
        state.days[dateKey] = log
    }

    /// Fuzzy title match used by the coach's update_block tool.
    func setBlockStatus(titled title: String, status: BlockStatus) -> Bool {
        var log = today
        let needle = title.lowercased()
        guard let index = log.blocks.firstIndex(where: {
            $0.title.lowercased().contains(needle) || needle.contains($0.title.lowercased())
        }) else { return false }
        log.blocks[index].status = status
        state.days[todayKey] = log
        return true
    }

    func cycleBlockStatus(_ id: UUID) {
        var log = today
        guard let index = log.blocks.firstIndex(where: { $0.id == id }) else { return }
        let next: BlockStatus
        switch log.blocks[index].status {
        case .planned: next = .done
        case .done: next = .missed
        case .missed: next = .skipped
        case .skipped: next = .planned
        }
        log.blocks[index].status = next
        state.days[todayKey] = log
    }

    /// Blocks whose end time has passed but are still unresolved.
    var overdueBlocks: [TimeBlock] {
        let now = Calendar.current.component(.hour, from: Date()) * 60
            + Calendar.current.component(.minute, from: Date())
        return today.blocks.filter { $0.status == .planned && $0.endMinutes <= now }
    }

    func saveEveningReflection(_ text: String) {
        var log = today
        log.eveningReflection = text
        state.days[todayKey] = log
    }

    // MARK: - Habits

    /// Replaces the habit list, preserving ids (and therefore history) for
    /// habits whose titles match.
    func setHabits(_ habits: [Habit]) {
        var updated = habits
        for (index, habit) in updated.enumerated() {
            if let existing = state.habits.first(where: {
                $0.title.lowercased() == habit.title.lowercased()
            }) {
                updated[index].id = existing.id
                updated[index].createdAt = existing.createdAt
            }
        }
        state.habits = updated
    }

    func toggleHabit(_ id: UUID) {
        var log = today
        if let index = log.habitsDone.firstIndex(of: id) {
            log.habitsDone.remove(at: index)
        } else {
            log.habitsDone.append(id)
        }
        state.days[todayKey] = log
    }

    func habitDoneToday(_ id: UUID) -> Bool {
        today.habitsDone.contains(id)
    }

    /// (done, scheduled) over the trailing `days` days, including today.
    func habitAdherence(_ habit: Habit, days: Int = 14) -> (done: Int, scheduled: Int) {
        let calendar = Calendar.current
        var done = 0
        var scheduled = 0
        for offset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            guard habit.isScheduled(on: date) else { continue }
            scheduled += 1
            if let log = state.days[Self.key(for: date)], log.habitsDone.contains(habit.id) {
                done += 1
            }
        }
        return (done, scheduled)
    }

    // MARK: - Metrics

    func logMetric(name: String, unit: String, value: Double) {
        let needle = name.lowercased()
        if let index = state.metrics.firstIndex(where: { $0.name.lowercased() == needle }) {
            state.metrics[index].samples.append(MetricSample(value: value))
            if !unit.isEmpty { state.metrics[index].unit = unit }
        } else {
            state.metrics.append(MetricSeries(name: name, unit: unit,
                                              samples: [MetricSample(value: value)]))
        }
    }

    // MARK: - Goals

    func goalIndex(matching title: String) -> Int? {
        let needle = title.lowercased()
        return state.goals.firstIndex(where: {
            $0.title.lowercased().contains(needle) || needle.contains($0.title.lowercased())
        })
    }

    // MARK: - Coach memory

    func upsertMemory(section title: String, content: String) {
        let needle = title.lowercased()
        if let index = state.coachMemory.firstIndex(where: { $0.title.lowercased() == needle }) {
            if content.isEmpty {
                state.coachMemory.remove(at: index)
            } else {
                state.coachMemory[index].content = content
                state.coachMemory[index].updatedAt = Date()
            }
        } else if !content.isEmpty {
            state.coachMemory.append(MemorySection(title: title, content: content))
        }
    }

    // MARK: - Chat

    func appendChat(role: String, text: String, inputRequest: InputRequest? = nil) {
        state.chat.append(ChatMessage(role: role, text: text, inputRequest: inputRequest))
        if state.chat.count > 400 {
            state.chat.removeFirst(state.chat.count - 400)
        }
    }

    // MARK: - Scoring

    func dayWon(_ date: Date) -> Bool {
        guard let log = state.days[Self.key(for: date)], !log.blocks.isEmpty else { return false }
        let resolved = log.blocks.allSatisfy { $0.status == .done || $0.status == .skipped }
        let didSomething = log.blocks.contains { $0.status == .done }
        return resolved && didSomething
    }

    var streak: Int {
        let calendar = Calendar.current
        var day = Date()
        var count = 0
        if !dayWon(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        while dayWon(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// (done, total) blocks across the trailing 7 days, including today.
    var weeklyStats: (completed: Int, assigned: Int) {
        let calendar = Calendar.current
        var completed = 0
        var assigned = 0
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()),
                  let log = state.days[Self.key(for: date)] else { continue }
            assigned += log.blocks.count
            completed += log.blocks.filter { $0.status == .done }.count
        }
        return (completed, assigned)
    }

    /// Per-day completion fraction for charts, oldest first.
    func dailyCompletion(days: Int = 14) -> [(date: Date, fraction: Double)] {
        let calendar = Calendar.current
        var result: [(Date, Double)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            if let log = state.days[Self.key(for: date)], !log.blocks.isEmpty {
                let done = log.blocks.filter { $0.status == .done }.count
                result.append((date, Double(done) / Double(log.blocks.count)))
            } else {
                result.append((date, 0))
            }
        }
        return result
    }

    // MARK: - Lifecycle

    func completeOnboarding(profile: UserProfile, goals: [Goal]) {
        state.profile = profile
        state.goals = goals
        NotificationManager.scheduleDailyCheckIns(morningHour: profile.morningHour,
                                                  eveningHour: profile.eveningHour)
    }

    func resetAll() {
        state = AppState()
        NotificationManager.cancelAll()
    }
}
