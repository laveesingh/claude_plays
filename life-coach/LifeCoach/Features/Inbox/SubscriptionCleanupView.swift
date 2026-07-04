import SwiftUI

/// A sheet listing noise-lane senders the user has never opened but that carry an
/// unsubscribe affordance. Offers one-tap per-sender unsubscribe and a "Unsubscribe
/// all" batch action, both routed through the existing `InboxCapabilities` layer so
/// they are tracked the same way as any other unsubscribe action in the inbox.
///
/// Reachable from the gear menu in the Inbox header → Inbox preferences →
/// "Unsubscribe sweep".
struct SubscriptionCleanupView: View {
    @ObservedObject var inbox: InboxStore
    @Environment(\.dismiss) private var dismiss

    /// IDs currently being processed (shows a spinner on the row).
    @State private var processing: Set<String> = []
    /// IDs that have been successfully unsubscribed this session.
    @State private var done: Set<String> = []
    /// Whether the batch-unsubscribe is running.
    @State private var batchRunning = false
    /// Error surfaced by a failed unsubscribe.
    @State private var errorMessage: String?

    private var candidates: [UnsubscribeCandidate] {
        inbox.neverOpenedNoiseSenders.filter { !done.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty && !batchRunning {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Unsubscribe sweep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !candidates.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(batchRunning ? "Working…" : "Unsubscribe all") {
                            Task { await batchUnsubscribe() }
                        }
                        .disabled(batchRunning)
                    }
                }
            }
            .alert("Unsubscribe failed", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                ForEach(candidates) { candidate in
                    row(for: candidate)
                }
            } header: {
                Text("\(candidates.count) sender\(candidates.count == 1 ? "" : "s") you've never opened")
            } footer: {
                Text("Unsubscribing opens the sender's one-click link or a mailto: draft — same as tapping Unsubscribe on an individual email.")
            }
        }
    }

    private func row(for candidate: UnsubscribeCandidate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.senderName)
                    .font(.body)
                Text("\(candidate.count) email\(candidate.count == 1 ? "" : "s") in Everything else")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if processing.contains(candidate.id) {
                ProgressView()
                    .controlSize(.small)
            } else if done.contains(candidate.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Unsubscribe") {
                    Task { await unsubscribe(candidate) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "All clear",
            systemImage: "checkmark.seal.fill",
            description: Text("No unsubscribable noise senders right now. Check back after the next refresh.")
        )
    }

    // MARK: - Actions

    /// Unsubscribe from a single sender via the capability layer.
    private func unsubscribe(_ candidate: UnsubscribeCandidate) async {
        guard !processing.contains(candidate.id) else { return }
        processing.insert(candidate.id)
        defer { processing.remove(candidate.id) }

        guard let caps = inbox.capabilities else {
            errorMessage = "Inbox capabilities unavailable. Please reopen the Inbox."
            return
        }

        do {
            _ = try await caps.run("unsubscribe", args: ["message_id": candidate.exampleID])
            done.insert(candidate.id)
            // Record the learning signal (M4).
            inbox.signalUnsubscribed(candidate.exampleID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Unsubscribe from every remaining candidate, sequentially.
    private func batchUnsubscribe() async {
        guard let caps = inbox.capabilities else {
            errorMessage = "Inbox capabilities unavailable. Please reopen the Inbox."
            return
        }
        batchRunning = true
        defer { batchRunning = false }

        for candidate in candidates {
            guard !done.contains(candidate.id), !processing.contains(candidate.id) else { continue }
            processing.insert(candidate.id)
            do {
                _ = try await caps.run("unsubscribe", args: ["message_id": candidate.exampleID])
                done.insert(candidate.id)
                inbox.signalUnsubscribed(candidate.exampleID)
            } catch {
                // Best-effort: log and continue with the next sender.
            }
            processing.remove(candidate.id)
        }
    }
}
