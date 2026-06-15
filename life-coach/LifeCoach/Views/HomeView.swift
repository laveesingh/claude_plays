import SwiftUI

/// The Sapiod hub / launchpad (Home tab). Surfaces the Sapiod identity, a coach
/// "Today" glance, and live glance cards for the real features (Inbox / News /
/// Factscroll), each tappable to jump into its tab. The gear in the toolbar opens
/// Settings (which is no longer a tab).
///
/// The feature glances read from per-feature stores that load their on-disk cache
/// synchronously in `init`. Home only ever READS those cached published values to
/// render a glance — it never triggers a `refresh()`/generation from here.
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: Router

    // Feature stores, built with the shared AppStore (mirrors how RootView builds
    // InboxView(store:) etc.). These load their cache in init, so the glances have
    // content at launch. We only read their cached published properties here.
    // TODO: hoist feature stores to app-level for always-live glances
    @StateObject private var inbox: InboxStore
    @StateObject private var news: NewsStore
    @StateObject private var factscroll: FactscrollStore

    init(store: AppStore) {
        _inbox = StateObject(wrappedValue: InboxStore(store: store))
        _news = StateObject(wrappedValue: NewsStore(store: store))
        _factscroll = StateObject(wrappedValue: FactscrollStore(store: store))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    todayCard
                    glancesSection
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

    // MARK: - Feature glances

    private var glancesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            inboxCard
            newsCard
            factscrollCard
        }
    }

    // MARK: Inbox glance

    /// Important-and-unread classified emails, newest first.
    private var importantUnread: [ClassifiedEmail] {
        inbox.emails
            .filter { $0.important && $0.email.isUnread }
            .sorted { $0.email.date > $1.email.date }
    }

    private var totalUnread: Int {
        inbox.emails.filter { $0.email.isUnread }.count
    }

    private var inboxCard: some View {
        glanceCard(
            icon: AppFeature.inbox.systemImage,
            iconTint: .red,
            title: AppFeature.inbox.title,
            trailing: importantUnread.isEmpty
                ? nil
                : "\(importantUnread.count) important"
        ) {
            router.selectedTab = .inbox
        } content: {
            if inbox.emails.isEmpty {
                glanceBody("Triage your inbox.")
            } else if let top = importantUnread.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(top.email.senderName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(top.email.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if totalUnread > 0 {
                        Text(unreadSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                glanceBody(totalUnread > 0
                    ? "\(unreadSummary) — nothing urgent."
                    : "You're all caught up.")
            }
        }
    }

    private var unreadSummary: String {
        totalUnread == 1 ? "1 unread" : "\(totalUnread) unread"
    }

    // MARK: News glance

    /// Newest story first (NewsStore keeps `stories` newest-first).
    private var latestStory: NewsStory? { news.stories.first }

    private var newsCard: some View {
        glanceCard(
            icon: AppFeature.news.systemImage,
            iconTint: .blue,
            title: AppFeature.news.title,
            trailing: news.stories.isEmpty
                ? nil
                : (news.stories.count == 1 ? "1 story" : "\(news.stories.count) stories")
        ) {
            router.selectedTab = .news
        } content: {
            if let story = latestStory {
                VStack(alignment: .leading, spacing: 6) {
                    Text(story.headline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(story.interestLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                glanceBody("Add topics to follow.")
            }
        }
    }

    // MARK: Factscroll glance

    /// FactscrollStore appends new facts, so the most recent is the last one.
    private var latestFact: Fact? { factscroll.facts.last }

    private var factscrollCard: some View {
        glanceCard(
            icon: AppFeature.factscroll.systemImage,
            iconTint: .purple,
            title: AppFeature.factscroll.title,
            trailing: nil
        ) {
            router.selectedTab = .factscroll
        } content: {
            if let fact = latestFact {
                Text(fact.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                glanceBody("Tap for a fact.")
            }
        }
    }

    // MARK: - Glance card chrome

    /// A reusable rounded glance card: an icon + title row (with optional trailing
    /// count), a body slot, and a chevron affordance. The whole card is one button.
    private func glanceCard<Content: View>(
        icon: String,
        iconTint: Color,
        title: String,
        trailing: String?,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(iconTint)
                        .frame(width: 24)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                content()
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func glanceBody(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
