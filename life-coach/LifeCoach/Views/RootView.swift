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
                    .tabItem { Label("Today", systemImage: "calendar.day.timeline.left") }
                    .tag(Router.Tab.today)
                ChatView()
                    .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right.fill") }
                    .tag(Router.Tab.coach)
                ProgressTabView()
                    .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
                    .tag(Router.Tab.progress)
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
