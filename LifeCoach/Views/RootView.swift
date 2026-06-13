import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: Router

    var body: some View {
        if store.state.profile == nil {
            OnboardingView()
        } else {
            TabView(selection: $router.selectedTab) {
                TodayView()
                    .tabItem { Label("Today", systemImage: "checklist") }
                    .tag(Router.Tab.today)
                ChatView()
                    .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right.fill") }
                    .tag(Router.Tab.coach)
                GoalsView()
                    .tabItem { Label("Goals", systemImage: "target") }
                    .tag(Router.Tab.goals)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(Router.Tab.settings)
            }
        }
    }
}
