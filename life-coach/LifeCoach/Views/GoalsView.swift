import SwiftUI

struct GoalsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAddGoal = false

    var body: some View {
        List {
            if store.state.goals.isEmpty {
                Text("No goals yet. Add one — your coach can't push you toward nothing.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.state.goals) { goal in
                NavigationLink {
                    GoalDetailView(goal: goal)
                } label: {
                    GoalRow(goal: goal)
                }
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            Button {
                showingAddGoal = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add goal")
        }
        .sheet(isPresented: $showingAddGoal) {
            AddGoalSheet()
        }
    }
}

struct GoalRow: View {
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: goal.category.icon)
                    .foregroundStyle(.tint)
                Text(goal.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ProgressView(value: goal.progressPercent, total: 100)
            HStack {
                Text("\(Int(goal.progressPercent))%")
                let open = goal.milestones.filter { !$0.isDone }.count
                if open > 0 {
                    Text("· \(open) open milestone\(open == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let target = goal.weeklyTarget, !target.isEmpty {
                Text("This week: \(target)")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

struct GoalDetailView: View {
    @EnvironmentObject private var store: AppStore
    let goal: Goal

    /// Live copy from the store so coach updates appear while the view is open.
    private var current: Goal {
        store.state.goals.first(where: { $0.id == goal.id }) ?? goal
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !current.why.isEmpty {
                        Text("Why: \(current.why)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ProgressView(value: current.progressPercent, total: 100)
                    Text("\(Int(current.progressPercent))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let target = current.weeklyTarget, !target.isEmpty {
                        Text("This week's target: \(target)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Milestones") {
                if current.milestones.isEmpty {
                    Text("The coach breaks this goal into deadlined milestones during intake.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(current.milestones) { milestone in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: milestone.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(milestone.isDone ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(milestone.title)
                                    .strikethrough(milestone.isDone)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let deadline = milestone.deadline {
                                    Text("Due \(deadline, style: .date)")
                                        .font(.caption)
                                        .foregroundStyle(deadlineColor(milestone))
                                }
                            }
                        }
                    }
                }
            }
            Section("Progress log") {
                if current.progressNotes.isEmpty {
                    Text("Nothing logged yet. Report progress to your coach and it lands here.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(current.progressNotes.reversed()) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.note)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(note.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(current.category.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deadlineColor(_ milestone: Milestone) -> Color {
        guard !milestone.isDone, let deadline = milestone.deadline else { return .secondary }
        return deadline < Date() ? .red : .secondary
    }
}

struct AddGoalSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var why = ""
    @State private var category: GoalCategory = .fitness

    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $category) {
                    ForEach(GoalCategory.allCases) { Text($0.label).tag($0) }
                }
                TextField("Goal", text: $title, axis: .vertical)
                TextField("Why it matters", text: $why, axis: .vertical)
            }
            .navigationTitle("New goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.state.goals.append(
                            Goal(category: category,
                                 title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 why: why.trimmingCharacters(in: .whitespacesAndNewlines))
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
