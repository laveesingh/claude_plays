import SwiftUI

/// The Coach tab. Provides the single `NavigationStack` for the coach's four
/// existing screens (Chat / Today / Progress / Goals), selected by a segmented
/// `Picker`. The sub-views no longer wrap themselves in a `NavigationStack`;
/// they only set their `.navigationTitle`/`.toolbar`, which this stack renders.
struct CoachHomeView: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $router.coachSection) {
                    ForEach(CoachSection.allCases) { section in
                        Text(section.label).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                Divider()

                section
            }
        }
    }

    @ViewBuilder
    private var section: some View {
        switch router.coachSection {
        case .chat:
            ChatView()
        case .today:
            TodayView()
        case .progress:
            ProgressTabView()
        case .goals:
            GoalsView()
        }
    }
}
