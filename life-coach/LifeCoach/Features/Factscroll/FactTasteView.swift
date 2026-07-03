import SwiftUI

/// "Your taste" panel — a sheet that surfaces the learned topic weights and lets
/// the user nudge or reset them directly. Reached via the `slider.horizontal.3`
/// button overlaid on the Factscroll feed (top-trailing corner).
///
/// ## Liquid Glass / iOS 26 strategy
/// Uses `glassEffect(in:)` and `.buttonStyle(.glass)` when running on iOS 26+.
/// Falls back to `Color(.secondarySystemBackground)` / `.bordered` on iOS 17 – 25
/// — no minimum deployment target bump required.
///
/// ## Behaviour
/// - Topic rows appear only when at least one reaction has been recorded. An empty
///   state is shown while the feed has no taste data yet.
/// - + / − buttons call `store.adjustTopicWeight(_:by:)` which persists and
///   publishes immediately so the row's weight bar updates live.
/// - "Reset taste" calls `store.resetTaste()` with an `.alert` confirmation guard.
struct FactTasteView: View {
    @ObservedObject var store: FactscrollStore
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingReset = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Your taste")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert("Reset all taste?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { store.resetTaste() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The feed will return to its default order. Your liked and disliked facts are not deleted.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                explainerCard
                if store.topicTaste.isEmpty {
                    emptyState
                } else {
                    topicList
                    resetButton
                }
            }
            .padding()
        }
        .background(backgroundFill)
    }

    // MARK: - Explainer card

    private var explainerCard: some View {
        Group {
            if #available(iOS 26.0, *) {
                explainerBody
                    .padding()
                    .glassEffect(in: .rect(cornerRadius: 14))
            } else {
                explainerBody
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var explainerBody: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "dial.low")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Taste nudges, it doesn't lock")
                    .font(.subheadline.weight(.semibold))
                Text("These gently steer your feed. One reaction barely moves the dial; a consistent pattern over many shifts the mix gradually. The feed always stays varied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                strengthEvidence
                    .padding(.top, 6)
            }
        }
    }

    /// Live evidence that tuning is taking hold: the current taste strength
    /// (evidence-scaled from reaction count) with a small gauge bar.
    @ViewBuilder
    private var strengthEvidence: some View {
        let percent = Int((store.tasteStrength * 100).rounded())
        let count = store.reactionCount
        VStack(alignment: .leading, spacing: 4) {
            if count > 0 {
                Text("Taste strength \(percent)% — from \(count) reaction\(count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            } else {
                Text("Taste strength 0% — no reactions yet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(4, geo.size.width * store.tasteStrengthFraction),
                               height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Topic list

    private var topicList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Topics")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            Group {
                if #available(iOS 26.0, *) {
                    topicRows
                        .glassEffect(in: .rect(cornerRadius: 14))
                } else {
                    topicRows
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var topicRows: some View {
        VStack(spacing: 0) {
            ForEach(store.topicTaste, id: \.topic) { entry in
                TopicWeightRow(topic: entry.topic, weight: entry.weight) { delta in
                    store.adjustTopicWeight(entry.topic, by: delta)
                }
                if entry.topic != store.topicTaste.last?.topic {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No taste signal yet")
                .font(.headline)
            Text("Like or dislike a few facts and your topic mix will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Reset button

    private var resetButton: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Reset taste", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            } else {
                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Reset taste", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundFill: some View {
        if #available(iOS 26.0, *) {
            Color.clear
        } else {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
        }
    }
}

// MARK: - Topic weight row

/// One row in the taste panel: topic name, a proportional weight bar (green =
/// positive, red = negative), and + / − stepper buttons.
private struct TopicWeightRow: View {
    let topic: String
    let weight: Double
    let onAdjust: (Double) -> Void

    /// Maximum display bar width fraction at |weight| = 4.0 (after which the bar
    /// just stays full — it's decorative, not a precise scale).
    private static let barCapWeight = 4.0

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.capitalized)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                weightBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            steppers
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var weightBar: some View {
        GeometryReader { geo in
            let fraction = min(1.0, abs(weight) / Self.barCapWeight)
            let barWidth = geo.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.15))
                    .frame(height: 4)
                Capsule()
                    .fill(weight >= 0 ? Color.green : Color.red)
                    .frame(width: max(4, barWidth), height: 4)
            }
        }
        .frame(height: 4)
    }

    private var steppers: some View {
        HStack(spacing: 8) {
            // ±1.0 per tap: one tap ⇒ topicBias ≈ 0.3 × tanh(0.5) ≈ 0.14 — a
            // visible feed shift. (±0.5 was imperceptible under the tanh squash.)
            adjustButton(symbol: "minus", delta: -1.0)
            adjustButton(symbol: "plus", delta: +1.0)
        }
    }

    @ViewBuilder
    private func adjustButton(symbol: String, delta: Double) -> some View {
        if #available(iOS 26.0, *) {
            Button { onAdjust(delta) } label: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
        } else {
            Button { onAdjust(delta) } label: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
