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
                    tabRoot(feature)
                        .tabItem { Label(feature.title, systemImage: feature.systemImage) }
                        .tag(feature)
                }
            }
            .sheet(isPresented: $router.showSettings) {
                SettingsView()
            }
        }
    }

    /// Most tabs render `AppFeature.rootView` directly. The Inbox is the one
    /// exception: its `InboxStore` must be constructed with the `AppStore`, which
    /// `@EnvironmentObject` can't supply inside `InboxView.init` — so RootView
    /// (which already holds the store) builds it here and passes it in.
    @ViewBuilder
    private func tabRoot(_ feature: AppFeature) -> some View {
        switch feature {
        case .inbox:
            InboxView(store: store)
        case .news:
            NewsView(store: store)
        default:
            feature.rootView
        }
    }
}
