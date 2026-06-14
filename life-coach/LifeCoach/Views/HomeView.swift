import SwiftUI

/// The Sapiod hub / launchpad (Home tab). Surfaces the Sapiod identity, a coach
/// "Today" glance, and de-emphasized "Coming soon" cards for the features still
/// in flight. The gear in the toolbar opens Settings (which is no longer a tab).
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: Router

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    todayCard
                    comingSoonSection
                }
                .padding()
            }
            .navigationTitle("Sapiod")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sapiod")
                .font(.largeTitle.weight(.bold))
            Text(greeting)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        switch hour {
        case 5..<12: timeOfDay = "Good morning"
        case 12..<17: timeOfDay = "Good afternoon"
        case 17..<22: timeOfDay = "Good evening"
        default: timeOfDay = "Hello"
        }
        if let name = store.state.profile?.name, !name.isEmpty {
            return "\(timeOfDay), \(name)."
        }
        return "\(timeOfDay)."
    }

    // MARK: - Today glance

    /// The most relevant block to surface: the first overdue one, else the next
    /// upcoming planned block today.
    private var glanceBlock: TimeBlock? {
        if let overdue = store.overdueBlocks.first { return overdue }
        let now = Calendar.current.component(.hour, from: Date()) * 60
            + Calendar.current.component(.minute, from: Date())
        return store.today.blocks
            .filter { $0.status == .planned && $0.endMinutes > now }
            .sorted { $0.startMinutes < $1.startMinutes }
            .first
    }

    private var isGlanceOverdue: Bool {
        guard let block = glanceBlock else { return false }
        return store.overdueBlocks.contains(where: { $0.id == block.id })
    }

    private var todayCard: some View {
        Button {
            router.goToCoachToday()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Today", systemImage: "calendar.day.timeline.left")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
                        Text("\(store.streak)")
                            .font(.headline.weight(.bold))
                        Text("day streak")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let block = glanceBlock {
                    HStack(spacing: 10) {
                        Image(systemName: isGlanceOverdue ? "exclamationmark.triangle.fill" : "clock")
                            .foregroundStyle(isGlanceOverdue ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(block.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("\(block.timeRangeLabel)\(isGlanceOverdue ? " · overdue" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    Text("No blocks scheduled. Open the coach to timebox your day.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Coming soon

    private var comingSoonFeatures: [AppFeature] {
        [.inbox, .news, .factscroll]
    }

    private var comingSoonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coming soon")
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(comingSoonFeatures) { feature in
                comingSoonCard(feature)
            }
        }
    }

    private func comingSoonCard(_ feature: AppFeature) -> some View {
        HStack(spacing: 14) {
            Image(systemName: feature.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.subheadline.weight(.medium))
                Text(feature.teaser)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(0.7)
    }
}
