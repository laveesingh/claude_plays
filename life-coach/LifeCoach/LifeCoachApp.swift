import SwiftUI
import UserNotifications

@main
@MainActor
struct LifeCoachApp: App {
    @StateObject private var store: AppStore
    @StateObject private var engine: CoachEngine
    @StateObject private var router = Router()

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
        }
    }
}

/// Lets any view switch tabs (e.g. "Morning brief" on Today jumps to Coach).
final class Router: ObservableObject {
    @Published var selectedTab: Tab = .today

    enum Tab: Hashable {
        case today, coach, progress, goals, settings
    }
}
