import SwiftUI

/// The Sapiod shell. Builds the tab bar by iterating `AppFeature.allCases`, so
/// a future feature is a single new enum case. Settings is no longer a tab —
/// it's presented as a sheet driven by `router.showSettings` (opened from the
/// Home gear and the coach's missing-key banner).
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: Router

    var body: some View {
        if store.state.profile == nil {
            OnboardingView()
        } else {
            TabView(selection: $router.selectedTab) {
                ForEach(AppFeature.allCases) { feature in
                    feature.rootView
                        .tabItem { Label(feature.title, systemImage: feature.systemImage) }
                        .tag(feature)
                }
            }
            .sheet(isPresented: $router.showSettings) {
                SettingsView()
            }
        }
    }
}
