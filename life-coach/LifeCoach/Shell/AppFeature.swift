import SwiftUI

/// The Sapiod shell's top-level destinations. The tab bar is built by iterating
/// `AppFeature.allCases`, so adding a future feature is a single new case plus
/// its `title`/`systemImage`/`rootView`. Kept deliberately as a plain enum +
/// switch rather than a plugin framework.
enum AppFeature: String, CaseIterable, Identifiable, Hashable {
    case home
    case coach
    case bulbs
    case inbox
    case news
    case factscroll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .coach: return "Coach"
        case .bulbs: return "Bulbs"
        case .inbox: return "Inbox"
        case .news: return "News"
        case .factscroll: return "Factscroll"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .coach: return "bubble.left.and.bubble.right.fill"
        case .bulbs: return "lightbulb.2.fill"
        case .inbox: return "tray.fill"
        case .news: return "newspaper.fill"
        case .factscroll: return "rectangle.stack.fill"
        }
    }

    @ViewBuilder
    var rootView: some View {
        switch self {
        case .home:
            // Home is always built by RootView.tabRoot via HomeView(store:) so its
            // glance cards can read the feature caches; this branch is unreachable.
            EmptyView()
        case .coach:
            CoachHomeView()
        case .bulbs:
            QuboBulbsView()
        case .inbox:
            ComingSoonView(feature: .inbox)
        case .news:
            ComingSoonView(feature: .news)
        case .factscroll:
            ComingSoonView(feature: .factscroll)
        }
    }

    /// One-line teaser used by Home's "Coming soon" cards and the placeholder views.
    var teaser: String {
        switch self {
        case .home: return "Your Sapiod launchpad."
        case .coach: return "Your AI accountability coach."
        case .bulbs: return "Find and diagnose your powered Qubo bulbs."
        case .inbox: return "AI-triaged Gmail — what actually needs you, first."
        case .news: return "A web-grounded feed of the topics you follow."
        case .factscroll: return "A reels-style scroll of AI facts tuned to your taste."
        }
    }
}
