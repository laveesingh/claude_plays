import Foundation

enum CoachIntensity: String, Codable, CaseIterable, Identifiable {
    case supportive
    case balanced
    case drillSergeant

    var id: String { rawValue }

    var label: String {
        switch self {
        case .supportive: return "Supportive"
        case .balanced: return "Balanced"
        case .drillSergeant: return "Drill Sergeant"
        }
    }

    var summary: String {
        switch self {
        case .supportive: return "Warm and encouraging. Celebrates wins, nudges gently."
        case .balanced: return "Direct and honest. Pushes you, but understands life happens."
        case .drillSergeant: return "Demanding. No excuses. Calls out slipping immediately."
        }
    }

    var promptDescription: String {
        switch self {
        case .supportive:
            return "Coach style: supportive. Be warm and encouraging. Celebrate every win, frame setbacks as learning, and nudge gently but persistently. Never let warmth turn into letting things slide - always end with a concrete next step."
        case .balanced:
            return "Coach style: balanced. Be direct and honest. Push the client to do more than they think they can, acknowledge real-life constraints, and don't sugarcoat when they're underperforming. Praise must be earned."
        case .drillSergeant:
            return "Coach style: drill sergeant. Be demanding and blunt. Accept no excuses, call out slipping immediately and specifically, and set aggressive but achievable standards. The client explicitly asked for this - they feel they've been taking things too slow and for granted. Be tough on behavior, never insulting about the person."
        }
    }
}

enum GoalCategory: String, Codable, CaseIterable, Identifiable {
    case fitness
    case professional
    case recovery
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitness: return "Fitness"
        case .professional: return "Professional"
        case .recovery: return "Recovery"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .fitness: return "figure.run"
        case .professional: return "briefcase.fill"
        case .recovery: return "bed.double.fill"
        case .other: return "star.fill"
        }
    }
}

// MARK: - Goals

struct ProgressNote: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var note: String
}

struct Milestone: Identifiable, Codable {
    var id = UUID()
    var title: String
    var deadline: Date?
    var isDone = false
}

struct Goal: Identifiable, Codable {
    var id = UUID()
    var category: GoalCategory
    var title: String
    var why: String
    var progressPercent: Double = 0
    var progressNotes: [ProgressNote] = []
    var milestones: [Milestone] = []
    var weeklyTarget: String?
}

// MARK: - The timeboxed day

enum BlockStatus: String, Codable {
    case planned   // not yet resolved
    case done
    case missed
    case skipped   // explicitly negotiated away with the coach

    var label: String {
        switch self {
        case .planned: return "Planned"
        case .done: return "Done"
        case .missed: return "Missed"
        case .skipped: return "Skipped"
        }
    }
}

struct TimeBlock: Identifiable, Codable {
    var id = UUID()
    var title: String
    var category: GoalCategory = .other
    /// Minutes from midnight, local time.
    var startMinutes: Int
    var durationMinutes: Int
    var status: BlockStatus = .planned

    var endMinutes: Int { startMinutes + durationMinutes }

    var timeRangeLabel: String {
        "\(Self.clock(startMinutes))-\(Self.clock(endMinutes))"
    }

    static func clock(_ minutes: Int) -> String {
        let bounded = max(0, min(minutes, 24 * 60 - 1))
        var components = DateComponents()
        components.hour = bounded / 60
        components.minute = bounded % 60
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

struct DayLog: Codable {
    var dateKey: String
    var blocks: [TimeBlock] = []
    var habitsDone: [UUID] = []
    var eveningReflection: String?
}

// MARK: - Habits

struct Habit: Identifiable, Codable {
    var id = UUID()
    var title: String
    var category: GoalCategory = .other
    /// Calendar weekdays (1 = Sunday ... 7 = Saturday). Empty means every day.
    var weekdays: [Int] = []
    var createdAt = Date()

    func isScheduled(on date: Date) -> Bool {
        guard date >= Calendar.current.startOfDay(for: createdAt) else { return false }
        if weekdays.isEmpty { return true }
        return weekdays.contains(Calendar.current.component(.weekday, from: date))
    }

    var scheduleLabel: String {
        if weekdays.isEmpty { return "Daily" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted().compactMap { index in
            (1...7).contains(index) ? symbols[index - 1] : nil
        }.joined(separator: " ")
    }
}

// MARK: - Metrics

struct MetricSample: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var value: Double
}

struct MetricSeries: Identifiable, Codable {
    var id = UUID()
    var name: String
    var unit: String
    var samples: [MetricSample] = []
}

// MARK: - Coach memory & reports

struct MemorySection: Identifiable, Codable {
    var id = UUID()
    var title: String
    var content: String
    var updatedAt = Date()
}

struct WeeklyReport: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var title: String
    var content: String
}

// MARK: - Chat & profile

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: String // "user" or "assistant"
    var text: String
    var date = Date()
    /// When the coach wants a structured answer, it attaches the controls here.
    var inputRequest: InputRequest?
}

// MARK: - Structured input (coach-driven UI)

enum InputFieldType: String, Codable {
    case singleSelect = "single_select"
    case multiSelect = "multi_select"
    case scale
    case number
    case time
    case date
    case boolean
    case text
    /// Renders every block on today's schedule with a Done/Missed/Skipped
    /// control and writes the result straight into app state on submit.
    case blockStatus = "block_status"
}

struct InputField: Identifiable, Codable {
    var id = UUID()
    /// Stable key the coach supplied (used only for the readable summary label).
    var key: String
    var label: String
    var type: InputFieldType
    var options: [String] = []
    var min: Double?
    var max: Double?
    var step: Double?
    var unit: String?
    var placeholder: String?
    /// For selects: offer an "Other…" free-text entry in addition to the options.
    var allowCustom: Bool = false
}

struct InputRequest: Codable {
    var prompt: String?
    var fields: [InputField]
    var submitLabel: String?
}

struct UserProfile: Codable {
    var name: String
    var intensity: CoachIntensity = .balanced
    var morningHour: Int = 7
    var eveningHour: Int = 21
    var intakeComplete: Bool = false
    var calendarWriteEnabled: Bool = false
}

struct AppState: Codable {
    var profile: UserProfile?
    var goals: [Goal] = []
    var days: [String: DayLog] = [:]
    var habits: [Habit] = []
    var metrics: [MetricSeries] = []
    var coachMemory: [MemorySection] = []
    var weeklyReports: [WeeklyReport] = []
    var chat: [ChatMessage] = []
}
