import SwiftUI
import UIKit

/// The Inbox tab. AI-triaged Gmail: a "Needs your attention" section of rich
/// cards for important mail, an "Everything else" section of compact rows, and a
/// reading drawer for any message. Owns its `InboxStore` as a `@StateObject`;
/// because `InboxStore.init` needs the `AppStore` (which isn't reachable through
/// `@EnvironmentObject` inside `init`), `RootView` hands the store in explicitly.
struct InboxView: View {
    @StateObject private var inbox: InboxStore

    /// The message the reading drawer is showing, if any.
    @State private var reading: ClassifiedEmail?

    /// Auto-refresh on first appear is one-shot.
    @State private var didAutoRefresh = false

    /// A cache older than this on first appear triggers an automatic refresh.
    private static let staleAfter: TimeInterval = 30 * 60

    init(store: AppStore) {
        _inbox = StateObject(wrappedValue: InboxStore(store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Inbox")
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $reading) { item in
            ReadingDrawer(classified: item)
        }
        .task { await autoRefreshIfNeeded() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if inbox.emails.isEmpty {
            if inbox.isRefreshing {
                loadingState
            } else {
                emptyState
            }
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                InboxHeader(
                    total: inbox.emails.count,
                    unread: unreadCount,
                    lastUpdated: inbox.lastUpdated,
                    isRefreshing: inbox.isRefreshing,
                    onRefresh: { Task { await inbox.refresh() } }
                )

                if !needsAttention.isEmpty {
                    section(title: "Needs your attention") {
                        ForEach(needsAttention) { item in
                            Button { reading = item } label: {
                                AttentionCard(classified: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !everythingElse.isEmpty {
                    section(title: "Everything else") {
                        VStack(spacing: 0) {
                            ForEach(Array(everythingElse.enumerated()), id: \.element.id) { index, item in
                                Button { reading = item } label: {
                                    CompactRow(classified: item)
                                }
                                .buttonStyle(.plain)
                                if index < everythingElse.count - 1 {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding()
        }
        .refreshable { await inbox.refresh() }
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Inbox clear")
                .font(.title3.weight(.semibold))
            Text("Nothing to triage right now. Pull to refresh or tap below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await inbox.refresh() }
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
            Text("Triaging your inbox…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived data

    private var needsAttention: [ClassifiedEmail] {
        inbox.needsAttention.sorted { $0.email.date > $1.email.date }
    }

    private var everythingElse: [ClassifiedEmail] {
        inbox.everythingElse.sorted { $0.email.date > $1.email.date }
    }

    private var unreadCount: Int {
        inbox.emails.filter { $0.email.isUnread }.count
    }

    // MARK: - Auto refresh

    private func autoRefreshIfNeeded() async {
        guard !didAutoRefresh else { return }
        didAutoRefresh = true

        let isStale: Bool
        if let last = inbox.lastUpdated {
            isStale = Date().timeIntervalSince(last) > Self.staleAfter
        } else {
            isStale = true
        }

        if inbox.emails.isEmpty || isStale {
            await inbox.refresh()
        }
    }
}

// MARK: - Header

/// Thread/unread counts, "Updated <relative>" and the Refresh button.
private struct InboxHeader: View {
    let total: Int
    let unread: Int
    let lastUpdated: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(countLine)
                    .font(.headline)
                Text(updatedLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            .accessibilityLabel("Refresh inbox")
        }
    }

    private var countLine: String {
        let threads = "\(total) thread\(total == 1 ? "" : "s")"
        return unread > 0 ? "\(threads) · \(unread) unread" : threads
    }

    private var updatedLine: String {
        guard let lastUpdated else { return "Not refreshed yet" }
        return "Updated \(InboxFormat.relative(lastUpdated))"
    }
}

// MARK: - Attention card (important emails)

/// A rich card for an important email: sender + time, prominent subject, the
/// 2–3 line AI summary as the body, a colored category badge, an unread dot, and
/// the de-emphasized one-line reason footnote.
private struct AttentionCard: View {
    let classified: ClassifiedEmail

    private var email: EmailMessage { classified.email }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if email.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                }
                Text(email.senderName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(InboxFormat.relative(email.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(email.subject)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !classified.summary.isEmpty {
                Text(classified.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }

            HStack(alignment: .center, spacing: 8) {
                if let category = classified.category {
                    CategoryBadge(category: category)
                }
                if !classified.reason.isEmpty {
                    Text(classified.reason)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Compact row (everything else)

/// A single-line compact row: sender · subject · 1-line AI summary · time.
/// Unread rows are bolder with a filled dot.
private struct CompactRow: View {
    let classified: ClassifiedEmail

    private var email: EmailMessage { classified.email }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(email.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(email.senderName)
                        .font(.subheadline.weight(email.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(email.subject)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(InboxFormat.relative(email.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Prefer the 1-line AI summary; fall back to the snippet if absent.
    private var summaryLine: String {
        classified.summary.isEmpty ? email.snippet : classified.summary
    }
}

// MARK: - Category badge

/// A small, tasteful filled capsule for an `EmailCategory`.
private struct CategoryBadge: View {
    let category: EmailCategory

    var body: some View {
        Text(category.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(category.badgeColor, in: Capsule())
    }
}

// MARK: - Reading drawer

/// The bottom drawer for reading a single email: subject/sender/time header, the
/// AI summary up top, then the real full body. A single nav action opens Gmail.
private struct ReadingDrawer: View {
    let classified: ClassifiedEmail
    @Environment(\.dismiss) private var dismiss

    private var email: EmailMessage { classified.email }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if !classified.summary.isEmpty {
                        summaryBlock
                    }

                    Divider()

                    Text(email.body)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        InboxLinks.openInGmail(email)
                    } label: {
                        Label("Open in Gmail", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let category = classified.category {
                    CategoryBadge(category: category)
                }
                Spacer(minLength: 0)
                Text(InboxFormat.absolute(email.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(email.subject)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(email.senderName) · \(email.senderEmail)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Summary", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(classified.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Gmail linking

/// Centralized "Open in Gmail" routing. Tries the Gmail web permalink (the
/// universal link), then falls back to the Gmail app's custom scheme.
enum InboxLinks {
    static func openInGmail(_ email: EmailMessage) {
        // TODO: exact thread deep-link finalized during live Gmail wiring
        let permalink = URL(string: "https://mail.google.com/mail/u/0/#all/\(email.threadId)")
        let scheme = URL(string: "googlegmail://")

        if let permalink {
            UIApplication.shared.open(permalink, options: [:]) { opened in
                if !opened, let scheme {
                    UIApplication.shared.open(scheme)
                }
            }
        } else if let scheme {
            UIApplication.shared.open(scheme)
        }
    }
}

// MARK: - Formatting

/// Shared, locale-aware date formatting for the Inbox.
private enum InboxFormat {
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

    /// e.g. "Jun 14, 3:42 PM" for the reading drawer header.
    static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
