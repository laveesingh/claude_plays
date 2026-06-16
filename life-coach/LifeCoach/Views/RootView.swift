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
            TabView(selection: tabSelection) {
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

    /// Routes tab changes through `router.selectTab` so a re-tap of the active tab
    /// is detected (Factscroll turns it into "jump to newest" instead of the
    /// default "scroll to top").
    private var tabSelection: Binding<AppFeature> {
        Binding(get: { router.selectedTab }, set: { router.selectTab($0) })
    }

    /// Most tabs render `AppFeature.rootView` directly. The feature tabs (and Home,
    /// whose glance cards read the feature caches) are the exception: their stores
    /// must be constructed with the `AppStore`, which `@EnvironmentObject` can't
    /// supply inside `init` — so RootView (which already holds the store) builds
    /// them here and passes it in.
    @ViewBuilder
    private func tabRoot(_ feature: AppFeature) -> some View {
        switch feature {
        case .home:
            HomeView(store: store)
        case .inbox:
            InboxView(store: store)
        case .news:
            NewsView(store: store)
        case .factscroll:
            FactscrollView(store: store)
        default:
            feature.rootView
        }
    }
}
