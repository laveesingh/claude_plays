import SwiftUI
import Charts

struct ProgressTabView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                executionSection
                metricsSection
                reportsSection
                dossierSection
            }
            .navigationTitle("Progress")
        }
    }

    private var executionSection: some View {
        Section("Execution — last 14 days") {
            let data = store.dailyCompletion(days: 14)
            Chart(data, id: \.date) { entry in
                BarMark(
                    x: .value("Day", entry.date, unit: .day),
                    y: .value("Completion", entry.fraction)
                )
                .foregroundStyle(entry.fraction >= 1.0 ? Color.green : Color.accentColor)
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1.0]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let fraction = value.as(Double.self) {
                            Text("\(Int(fraction * 100))%")
                        }
                    }
                }
            }
            .frame(height: 160)
            .padding(.vertical, 4)

            ForEach(store.state.habits) { habit in
                let adherence = store.habitAdherence(habit)
                HStack {
                    Text(habit.title)
                        .font(.subheadline)
                    Spacer()
                    Text("\(adherence.done)/\(adherence.scheduled)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(adherenceColor(adherence))
                }
            }
        }
    }

    private func adherenceColor(_ adherence: (done: Int, scheduled: Int)) -> Color {
        guard adherence.scheduled > 0 else { return .secondary }
        let fraction = Double(adherence.done) / Double(adherence.scheduled)
        if fraction >= 0.8 { return .green }
        if fraction >= 0.5 { return .orange }
        return .red
    }

    private var metricsSection: some View {
        Section("Metrics") {
            if store.state.metrics.isEmpty {
                Text("Nothing logged yet. Report measurements to your coach — weight, run times, deep-work hours — and trends show up here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.state.metrics) { series in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(series.name).font(.headline)
                            Spacer()
                            if let latest = series.samples.last {
                                Text("\(latest.value, format: .number.precision(.fractionLength(0...1))) \(series.unit)")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        if series.samples.count >= 2 {
                            Chart(series.samples) { sample in
                                LineMark(
                                    x: .value("Date", sample.date),
                                    y: .value(series.name, sample.value)
                                )
                                PointMark(
                                    x: .value("Date", sample.date),
                                    y: .value(series.name, sample.value)
                                )
                            }
                            .frame(height: 100)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var reportsSection: some View {
        Section("Weekly report cards") {
            if store.state.weeklyReports.isEmpty {
                Text("Your coach writes a report card at every weekly review.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.state.weeklyReports.reversed()) { report in
                    NavigationLink {
                        ScrollView {
                            Text(report.content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle(report.title)
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.title).font(.subheadline.weight(.medium))
                            Text(report.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var dossierSection: some View {
        Section {
            if store.state.coachMemory.isEmpty {
                Text("Empty so far. The coach fills this in during intake and as it learns about you.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.state.coachMemory) { section in
                    DisclosureGroup(section.title) {
                        Text(section.content)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("What your coach knows about you")
        } footer: {
            Text("The coach's private client file — fully visible to you. It maintains these notes itself and consults them in every conversation.")
        }
    }
}
