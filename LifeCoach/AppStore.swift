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

    func setTodayPlan(_ tasks: [DailyTask]) {
        var log = today
        // Preserve completion state for tasks the coach kept with the same title.
        var updated = tasks
        for (index, task) in updated.enumerated() {
            if let existing = log.tasks.first(where: {
                $0.title.lowercased() == task.title.lowercased() && $0.isDone
            }) {
                updated[index].isDone = existing.isDone
            }
        }
        log.tasks = updated
        state.days[todayKey] = log
    }

    func addTask(_ task: DailyTask) {
        var log = today
        log.tasks.append(task)
        state.days[todayKey] = log
    }

    func toggleTask(_ id: UUID) {
        var log = today
        guard let index = log.tasks.firstIndex(where: { $0.id == id }) else { return }
        log.tasks[index].isDone.toggle()
        state.days[todayKey] = log
    }

    func saveEveningReflection(_ text: String) {
        var log = today
        log.eveningReflection = text
        state.days[todayKey] = log
    }

    // MARK: - Chat

    func appendChat(role: String, text: String) {
        state.chat.append(ChatMessage(role: role, text: text))
        // Keep the persisted transcript bounded.
        if state.chat.count > 400 {
            state.chat.removeFirst(state.chat.count - 400)
        }
    }

    // MARK: - Goals

    func recordProgress(goalTitle: String, note: String, percent: Double?) -> Bool {
        let needle = goalTitle.lowercased()
        guard let index = state.goals.firstIndex(where: {
            $0.title.lowercased().contains(needle) || needle.contains($0.title.lowercased())
        }) else { return false }
        state.goals[index].progressNotes.append(ProgressNote(note: note))
        if let percent {
            state.goals[index].progressPercent = min(100, max(0, percent))
        }
        return true
    }

    // MARK: - Stats

    func dayWon(_ date: Date) -> Bool {
        guard let log = state.days[Self.key(for: date)] else { return false }
        return !log.tasks.isEmpty && log.tasks.allSatisfy { $0.isDone }
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

    /// (completed, assigned) across the last 7 days, including today.
    var weeklyStats: (completed: Int, assigned: Int) {
        let calendar = Calendar.current
        var completed = 0
        var assigned = 0
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()),
                  let log = state.days[Self.key(for: date)] else { continue }
            assigned += log.tasks.count
            completed += log.tasks.filter { $0.isDone }.count
        }
        return (completed, assigned)
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
