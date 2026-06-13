import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: CoachEngine
    @EnvironmentObject private var router: Router

    @State private var showingEveningReview = false
    @State private var newTaskTitle = ""

    var body: some View {
        NavigationStack {
            List {
                streakSection
                checkInSection
                planSection
                addTaskSection
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

    private var streakSection: some View {
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
                    Text("done this week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
        }
    }

    private var checkInSection: some View {
        Section {
            Button {
                router.selectedTab = .coach
                Task {
                    await engine.send("Good morning, coach. Set my plan for today.")
                }
            } label: {
                Label("Morning check-in — get today's plan", systemImage: "sunrise.fill")
            }
            .disabled(engine.isResponding)

            Button {
                showingEveningReview = true
            } label: {
                Label("Evening review — report in", systemImage: "moon.stars.fill")
            }
        } header: {
            Text("Check-ins")
        }
    }

    private var planSection: some View {
        Section {
            if store.today.tasks.isEmpty {
                Text("No plan yet. Do a morning check-in and your coach will set one.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.today.tasks) { task in
                    Button {
                        store.toggleTask(task.id)
                    } label: {
                        HStack {
                            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.isDone ? Color.green : Color.secondary)
                            Text(task.title)
                                .strikethrough(task.isDone)
                                .foregroundStyle(task.isDone ? .secondary : .primary)
                            Spacer()
                            Image(systemName: task.category.icon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Today's plan")
        }
    }

    private var addTaskSection: some View {
        Section {
            HStack {
                TextField("Add your own task", text: $newTaskTitle)
                Button {
                    let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return }
                    store.addTask(DailyTask(title: title))
                    newTaskTitle = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
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
                Section("Today's results") {
                    if store.today.tasks.isEmpty {
                        Text("No tasks were assigned today.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.today.tasks) { task in
                            HStack {
                                Image(systemName: task.isDone ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(task.isDone ? Color.green : Color.red)
                                Text(task.title)
                            }
                        }
                    }
                }
                Section("How did the day really go?") {
                    TextField("Be honest — your coach will know anyway.", text: $reflection, axis: .vertical)
                        .lineLimit(4...8)
                }
            }
            .navigationTitle("Evening review")
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
        let tasks = store.today.tasks
        let done = tasks.filter { $0.isDone }.map { $0.title }
        let missed = tasks.filter { !$0.isDone }.map { $0.title }

        var message = "Evening review."
        message += done.isEmpty ? " Completed: nothing." : " Completed: \(done.joined(separator: "; "))."
        if !missed.isEmpty {
            message += " Missed: \(missed.joined(separator: "; "))."
        }
        let trimmed = reflection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            message += " My reflection: \(trimmed)"
        }

        dismiss()
        router.selectedTab = .coach
        Task {
            await engine.send(message)
        }
    }
}
