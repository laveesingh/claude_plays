import SwiftUI
import UserNotifications

@main
@MainActor
struct LifeCoachApp: App {
    @StateObject private var store: AppStore
    @StateObject private var engine: CoachEngine
    @StateObject private var router = Router()
    @StateObject private var settings = AppSettingsStore()

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _engine = StateObject(wrappedValue: CoachEngine(store: store))
        NotificationDelegate.shared.store = store
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        NotificationManager.registerCategories()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(router)
                .environmentObject(settings)
        }
    }
}

/// The Coach tab's nested sub-screens, selected by a segmented picker.
enum CoachSection: String, CaseIterable, Identifiable, Hashable {
    case chat, today, progress, goals

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .today: return "Today"
        case .progress: return "Progress"
        case .goals: return "Goals"
        }
    }
}

/// Lets any view drive the Sapiod shell — switch top-level tabs, pick the Coach
/// sub-section, and present Settings (which is no longer a tab).
@MainActor
final class Router: ObservableObject {
    @Published var selectedTab: AppFeature = .home
    @Published var coachSection: CoachSection = .chat
    @Published var showSettings = false

    /// Jump to the Coach tab's Chat sub-view (used by Today's session buttons).
    func goToCoachChat() {
        coachSection = .chat
        selectedTab = .coach
    }

    /// Jump to the Coach tab's Today sub-view (used by Home's glance card).
    func goToCoachToday() {
        coachSection = .today
        selectedTab = .coach
    }
}
