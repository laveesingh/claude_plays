import SwiftUI
import UserNotifications
import BackgroundTasks

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

        // M5: Register the background-refresh handler ONCE, before launch finishes
        // (iOS crashes on a late or duplicate registration). The handler builds its
        // own InboxStore from this AppStore when it fires, so background refresh works
        // even if the user never opens the Inbox tab. Then submit the first request.
        InboxWatchScheduler.register(appStore: store)
        InboxWatchScheduler.scheduleNext()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(router)
                .environmentObject(settings)
                .environmentObject(GoogleAuth.shared)
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

    /// Bumped whenever the user taps the Factscroll tab while already on it. The
    /// Factscroll feed observes this to jump to the bottom (newest) — repurposing
    /// the tab re-tap from its default "scroll to top" into "take me to the latest".
    @Published var factscrollResetToken = 0

    /// Switch tabs, detecting a re-tap of the already-selected tab so a feature can
    /// react (Factscroll uses it to jump to the newest content).
    func selectTab(_ tab: AppFeature) {
        if tab == selectedTab, tab == .factscroll {
            factscrollResetToken &+= 1
        }
        selectedTab = tab
    }

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
