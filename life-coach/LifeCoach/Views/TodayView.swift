import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: CoachEngine
    @EnvironmentObject private var router: Router

    @State private var showingEveningReview = false

    var body: some View {
        NavigationStack {
            List {
                scoreboard
                if !store.overdueBlocks.isEmpty {
                    overdueBanner
                }
                sessionSection
                scheduleSection
                habitsSection
            }
            .navigationTitle(dateTitle)
            .sheet(isPresented: $showingEveningReview) {
                EveningReviewSheet()
            }
        }
    }

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: Date())
    }

    private var scoreboard: some View {
        Section {
            HStack(spacing: 16) {
                VStack {
                    Text("\(store.streak)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("day streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Divider()
                VStack {
                    let stats = store.weeklyStats
                    Text("\(stats.completed)/\(stats.assigned)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("blocks this week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
        }
    }

    private var overdueBanner: some View {
        Section {
            Button {
                router.selectedTab = .coach
                Task {
                    await engine.send(
                        "(Midday correction triggered: the client has unresolved overdue blocks.)",
                        hidden: true,
                        session: .middayCorrection
                    )
                }
            } label: {
                Label {
                    Text("\(store.overdueBlocks.count) block\(store.overdueBlocks.count == 1 ? "" : "s") unresolved — the coach wants a word")
                        .font(.callout.weight(.medium))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .disabled(engine.isResponding)
        }
    }

    private var sessionSection: some View {
        Section("Sessions") {
            Button {
                router.selectedTab = .coach
                Task {
                    await engine.send("Good morning, coach. Run the morning brief.",
                                      session: .morningBrief)
                }
            } label: {
                Label("Morning brief — timebox my day", systemImage: "sunrise.fill")
            }
            .disabled(engine.isResponding)

            Button {
                showingEveningReview = true
            } label: {
                Label("Evening debrief — report in", systemImage: "moon.stars.fill")
            }

            Button {
                router.selectedTab = .coach
                Task {
                    await engine.send("Coach, let's do the weekly review.",
                                      session: .weeklyReview)
                }
            } label: {
                Label("Weekly review — full audit", systemImage: "chart.line.uptrend.xyaxis")
            }
            .disabled(engine.isResponding)
        }
    }

    private var scheduleSection: some View {
        Section {
            if store.today.blocks.isEmpty {
                Text("No schedule yet. Run the morning brief and your coach will timebox your day.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.today.blocks) { block in
                    BlockRow(block: block) {
                        store.cycleBlockStatus(block.id)
                    }
                }
            }
        } header: {
            Text("Today's schedule")
        } footer: {
            if !store.today.blocks.isEmpty {
                Text("Tap a block to cycle its status: planned → done → missed → skipped. Lock-screen check-ins update it automatically.")
            }
        }
    }

    private var habitsSection: some View {
        Section("Standing habits") {
            let scheduledToday = store.state.habits.filter { $0.isScheduled(on: Date()) }
            if scheduledToday.isEmpty {
                Text("No habits yet — the coach sets these during intake.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(scheduledToday) { habit in
                    Button {
                        store.toggleHabit(habit.id)
                    } label: {
                        HStack {
                            Image(systemName: store.habitDoneToday(habit.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(store.habitDoneToday(habit.id) ? Color.green : Color.secondary)
                            VStack(alignment: .leading) {
                                Text(habit.title)
                                let adherence = store.habitAdherence(habit)
                                Text("\(habit.scheduleLabel) · \(adherence.done)/\(adherence.scheduled) last 14 days")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: habit.category.icon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct BlockRow: View {
    let block: TimeBlock
    let onTap: () -> Void

    private var statusColor: Color {
        switch block.status {
        case .planned: return .secondary
        case .done: return .green
        case .missed: return .red
        case .skipped: return .orange
        }
    }

    private var statusIcon: String {
        switch block.status {
        case .planned: return "circle"
        case .done: return "checkmark.circle.fill"
        case .missed: return "xmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .trailing) {
                    Text(TimeBlock.clock(block.startMinutes))
                        .font(.caption.weight(.semibold))
                    Text("\(block.durationMinutes)m")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 64, alignment: .trailing)

                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(block.title)
                        .strikethrough(block.status == .done)
                        .foregroundStyle(block.status == .done ? .secondary : .primary)
                    Text(block.status.label)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                Image(systemName: block.category.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct EveningReviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: CoachEngine
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss

    @State private var reflection = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Today's record") {
                    if store.today.blocks.isEmpty {
                        Text("No schedule was set today.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.today.blocks) { block in
                            HStack {
                                Image(systemName: block.status == .done
                                      ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(block.status == .done ? Color.green : Color.red)
                                Text("\(block.timeRangeLabel)  \(block.title)")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                Section("How did the day really go?") {
                    TextField("Be honest — the coach checks the record anyway.",
                              text: $reflection, axis: .vertical)
                        .lineLimit(4...8)
                }
            }
            .navigationTitle("Evening debrief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send to coach") { submit() }
                        .disabled(engine.isResponding)
                }
            }
        }
    }

    private func submit() {
        store.saveEveningReflection(reflection)
        let blocks = store.today.blocks
        let done = blocks.filter { $0.status == .done }.map { $0.title }
        let unresolved = blocks.filter { $0.status == .planned || $0.status == .missed }
            .map { $0.title }

        var message = "Evening debrief."
        message += done.isEmpty ? " Completed: nothing." : " Completed: \(done.joined(separator: "; "))."
        if !unresolved.isEmpty {
            message += " Missed or unresolved: \(unresolved.joined(separator: "; "))."
        }
        let habitsDone = store.state.habits
            .filter { $0.isScheduled(on: Date()) && store.habitDoneToday($0.id) }
            .map { $0.title }
        if !habitsDone.isEmpty {
            message += " Habits done: \(habitsDone.joined(separator: "; "))."
        }
        let trimmed = reflection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            message += " My reflection: \(trimmed)"
        }

        dismiss()
        router.selectedTab = .coach
        Task {
            await engine.send(message, session: .eveningDebrief)
        }
    }
}
