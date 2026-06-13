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
            return "Coach style: supportive. Be warm and encouraging. Celebrate every win, frame setbacks as learning, and nudge gently but persistently. Never let warmth turn into letting things slide — always end with a concrete next step."
        case .balanced:
            return "Coach style: balanced. Be direct and honest. Push the client to do more than they think they can, acknowledge real-life constraints, and don't sugarcoat when they're underperforming. Praise must be earned."
        case .drillSergeant:
            return "Coach style: drill sergeant. Be demanding and blunt. Accept no excuses, call out slipping immediately and specifically, and set aggressive but achievable standards. The client explicitly asked for this — they feel they've been taking things too slow and for granted. Be tough on behavior, never insulting about the person."
        }
    }
}

enum GoalCategory: String, Codable, CaseIterable, Identifiable {
    case fitness
    case professional
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitness: return "Fitness"
        case .professional: return "Professional"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .fitness: return "figure.run"
        case .professional: return "briefcase.fill"
        case .other: return "star.fill"
        }
    }
}

struct ProgressNote: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var note: String
}

struct Goal: Identifiable, Codable {
    var id = UUID()
    var category: GoalCategory
    var title: String
    var why: String
    var progressPercent: Double = 0
    var progressNotes: [ProgressNote] = []
}

struct DailyTask: Identifiable, Codable {
    var id = UUID()
    var title: String
    var category: GoalCategory = .other
    var isDone: Bool = false
}

struct DayLog: Codable {
    var dateKey: String
    var tasks: [DailyTask] = []
    var eveningReflection: String?
}

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: String // "user" or "assistant"
    var text: String
    var date = Date()
}

struct UserProfile: Codable {
    var name: String
    var intensity: CoachIntensity = .balanced
    var morningHour: Int = 7
    var eveningHour: Int = 21
}

struct AppState: Codable {
    var profile: UserProfile?
    var goals: [Goal] = []
    var days: [String: DayLog] = [:]
    var chat: [ChatMessage] = []
}
