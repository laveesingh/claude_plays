import SwiftUI
import UIKit

/// The News tab. A topic-driven, web-grounded feed: a newest-first timeline of
/// story cards (each tagged with its interest label and number), a reading drawer
/// with the full summary and tappable sources, and a topics editor. Owns its
/// `NewsStore` as a `@StateObject`; like the Inbox, the `AppStore` is handed in
/// explicitly because `@EnvironmentObject` can't supply it inside `init`.
struct NewsView: View {
    @StateObject private var news: NewsStore

    /// The story the reading drawer is showing, if any.
    @State private var reading: NewsStory?

    /// Whether the topics editor sheet is up.
    @State private var editingTopics = false

    /// Auto-refresh on first appear is one-shot.
    @State private var didAutoRefresh = false

    /// A feed older than this on first appear triggers an automatic refresh.
    private static let staleAfter: TimeInterval = 30 * 60

    init(store: AppStore) {
        _news = StateObject(wrappedValue: NewsStore(store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("News")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            editingTopics = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Edit topics")
                    }
                }
        }
        .sheet(item: $reading) { story in
            StoryDrawer(story: story)
        }
        .sheet(isPresented: $editingTopics) {
            TopicsEditor(news: news)
        }
        .task { await autoRefreshIfNeeded() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if news.topics.isEmpty {
            noTopicsState
        } else if news.stories.isEmpty {
            if news.isRefreshing {
                loadingState
            } else {
                noStoriesState
            }
        } else {
            feed
        }
    }

    /// Stories bucketed into newest-first day groups (by their own date, not fetch
    /// time), each bucket sorted newest story first — the data behind the sectioned
    /// timeline.
    private var dayGroups: [(day: Date, stories: [NewsStory])] {
        let cal = Calendar.current
        return Dictionary(grouping: news.stories) { cal.startOfDay(for: $0.displayDate) }
            .map { (day: $0.key, stories: $0.value.sorted {
                $0.displayDate != $1.displayDate ? $0.displayDate > $1.displayDate
                                                 : $0.storyNumber > $1.storyNumber
            }) }
            .sorted { $0.day > $1.day }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                NewsHeader(
                    lastUpdated: news.lastUpdated,
                    isRefreshing: news.isRefreshing,
                    onRefresh: { Task { await news.refresh() } }
                )
                .padding(.horizontal)

                ForEach(dayGroups, id: \.day) { group in
                    Section {
                        ForEach(group.stories) { story in
                            Button { reading = story } label: {
                                StoryCard(story: story)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                    } header: {
                        DateSectionHeader(day: group.day)
                    }
                }
            }
            .padding(.vertical)
        }
        .refreshable { await news.refresh() }
    }

    // MARK: - States

    private var noTopicsState: some View {
        VStack(spacing: 14) {
            Image(systemName: "newspaper")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No topics yet")
                .font(.title3.weight(.semibold))
            Text("Add topics your coach should track and you'll get a web-grounded feed on each one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                editingTopics = true
            } label: {
                Label("Add topics", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noStoriesState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No stories yet")
                .font(.title3.weight(.semibold))
            Text("Pull to refresh to search the web for your \(news.topics.count) topic\(news.topics.count == 1 ? "" : "s").")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await news.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Searching the web…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Auto refresh

    private func autoRefreshIfNeeded() async {
        guard !didAutoRefresh else { return }
        didAutoRefresh = true
        guard !news.topics.isEmpty else { return }

        let isStale: Bool
        if let last = news.lastUpdated {
            isStale = Date().timeIntervalSince(last) > Self.staleAfter
        } else {
            isStale = true
        }

        if news.stories.isEmpty || isStale {
            await news.refresh()
        }
    }
}

// MARK: - Header

/// "Updated <relative>" plus the Refresh button.
private struct NewsHeader: View {
    let lastUpdated: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(updatedLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh news")
        }
    }

    private var updatedLine: String {
        guard let lastUpdated else { return "Not refreshed yet" }
        return "Updated \(NewsFormat.relative(lastUpdated))"
    }
}

// MARK: - Story card

/// A clean timeline card: header row with "#N", the interest-label badge, and a
/// relative timestamp; body is the short `summary1`.
private struct StoryCard: View {
    let story: NewsStory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("#\(story.storyNumber)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                InterestBadge(label: story.interestLabel)
                Spacer(minLength: 0)
                Text(NewsFormat.day(story.displayDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(story.headline)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(story.summary1)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Date section header

/// A pinned timeline divider — "Today" / "Yesterday" / weekday / full date. The
/// bar material keeps it legible while it sticks over scrolling cards.
private struct DateSectionHeader: View {
    let day: Date

    var body: some View {
        HStack {
            Text(NewsFormat.daySection(day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

// MARK: - Interest badge

/// A small, tasteful capsule for a topic's interest label. Color is derived
/// deterministically from the label so each topic keeps a consistent hue.
private struct InterestBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NewsFormat.color(for: label), in: Capsule())
    }
}

// MARK: - Reading drawer

/// The bottom drawer for one story: header (#N, badge, time), the long
/// `summary2`, then the sources as tappable links.
private struct StoryDrawer: View {
    let story: NewsStory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    Text(story.summary2)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if !story.sources.isEmpty {
                        Divider()
                        sourcesBlock
                    }
                }
                .padding()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(story.storyNumber)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                InterestBadge(label: story.interestLabel)
                Spacer(minLength: 0)
                Text(NewsFormat.day(story.displayDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(story.headline)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourcesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sources", systemImage: "link")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(story.sources) { source in
                Button {
                    if let url = URL(string: source.url) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .font(.subheadline)
                                .foregroundStyle(.tint)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(NewsFormat.host(source.url))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Topics editor

/// Add / edit / delete the free-text topics that drive the feed.
private struct TopicsEditor: View {
    @ObservedObject var news: NewsStore
    @Environment(\.dismiss) private var dismiss

    @State private var newTopic = ""
    @State private var editing: Topic?
    @State private var editText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a topic…", text: $newTopic)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button(action: add) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text("Free text — a subject, a question, a beat. Your coach searches the web on each.")
                }

                if !news.topics.isEmpty {
                    Section("Tracking") {
                        ForEach(news.topics) { topic in
                            Button {
                                editing = topic
                                editText = topic.text
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(topic.text)
                                            .foregroundStyle(.primary)
                                        Text(topic.normalizedLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "pencil")
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Topics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Edit topic", isPresented: editingBinding) {
                TextField("Topic", text: $editText)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { editing = nil }
                Button("Save") {
                    if let topic = editing { news.updateTopic(topic, to: editText) }
                    editing = nil
                }
            }
        }
    }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }

    private func add() {
        let text = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        news.addTopic(text)
        newTopic = ""
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            news.removeTopic(news.topics[index])
        }
    }
}

// MARK: - Formatting

/// Shared, locale-aware formatting + deterministic badge colors for News.
private enum NewsFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// e.g. "3h ago", "now".
    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// e.g. "Jun 14, 3:42 PM" for the drawer header.
    static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Sticky timeline section label: "Today", "Yesterday", a weekday within the
    /// last week, else "Jun 14, 2026".
    static func daySection(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        if (0..<7).contains(days) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Date-only label (no time) for a story's own date, e.g. "Jun 14, 2026".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Bare host for a source URL, e.g. "reuters.com".
    static func host(_ urlString: String) -> String {
        guard let host = URL(string: urlString)?.host else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A stable, pleasant hue derived from the interest label so each topic keeps
    /// a consistent badge color.
    static func color(for label: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .red]
        var hash = 5381
        for scalar in label.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        let index = abs(hash) % palette.count
        return palette[index]
    }
}
