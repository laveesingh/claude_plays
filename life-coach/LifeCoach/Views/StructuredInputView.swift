import SwiftUI

/// Renders the coach's `request_user_input` spec as clean native controls and
/// turns the answers into a readable message. A `block_status` field also writes
/// the day's block outcomes straight into app state on submit, so progress never
/// depends on the model remembering to call a tool.
struct StructuredInputView: View {
    @EnvironmentObject private var store: AppStore

    let request: InputRequest
    var disabled: Bool
    /// Hands a completion to the chat view, which presents the voice sheet and
    /// returns the transcript here.
    var presentVoice: (@escaping (String) -> Void) -> Void
    var onSubmit: (String) -> Void

    static let otherMarker = "\u{2063}other"

    @State private var singleChoice: [UUID: String] = [:]
    @State private var multiChoice: [UUID: Set<String>] = [:]
    @State private var customText: [UUID: String] = [:]
    @State private var scaleValue: [UUID: Double] = [:]
    @State private var boolValue: [UUID: Bool] = [:]
    @State private var dateValue: [UUID: Date] = [:]
    @State private var blockChoice: [UUID: BlockStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let prompt = request.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.subheadline.weight(.semibold))
            }
            ForEach(request.fields) { field in
                VStack(alignment: .leading, spacing: 10) {
                    if showLabel(for: field) {
                        Text(field.label)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    fieldControl(field)
                }
            }
            Button {
                applyBlockStatuses()
                onSubmit(summary())
            } label: {
                Text(request.submitLabel ?? "Send")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(disabled || !hasAnswer)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground),
                   in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal)
    }

    private func showLabel(for field: InputField) -> Bool {
        guard field.type != .blockStatus else { return false }
        return request.fields.count > 1 || (request.prompt?.isEmpty == false)
    }

    // MARK: - Controls

    @ViewBuilder
    private func fieldControl(_ field: InputField) -> some View {
        switch field.type {
        case .singleSelect:
            selectControl(field, options: optionsWithOther(field), multi: false) { option in
                singleChoice[field.id] == option
            } toggle: { option in
                singleChoice[field.id] = option
            }
            if singleChoice[field.id] == Self.otherMarker {
                textField(field, placeholder: "Type your answer")
            }

        case .multiSelect:
            selectControl(field, options: field.options, multi: true) { option in
                multiChoice[field.id, default: []].contains(option)
            } toggle: { option in
                var set = multiChoice[field.id, default: []]
                if set.contains(option) { set.remove(option) } else { set.insert(option) }
                multiChoice[field.id] = set
            }
            if field.allowCustom {
                textField(field, placeholder: "Add another…")
            }

        case .scale:
            scaleControl(field)

        case .number:
            numberControl(field)

        case .time:
            DatePicker("", selection: dateBinding(field), displayedComponents: .hourAndMinute)
                .labelsHidden()

        case .date:
            DatePicker("", selection: dateBinding(field), displayedComponents: .date)
                .labelsHidden()

        case .boolean:
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach([true, false], id: \.self) { value in
                    Chip(title: value ? "Yes" : "No",
                         selected: boolValue[field.id] == value) {
                        boolValue[field.id] = value
                    }
                }
            }

        case .text:
            textField(field, placeholder: field.placeholder ?? "Type your answer")

        case .blockStatus:
            blockStatusControl()
        }
    }

    @ViewBuilder
    private func selectControl(_ field: InputField,
                               options: [String],
                               multi: Bool,
                               isSelected: @escaping (String) -> Bool,
                               toggle: @escaping (String) -> Void) -> some View {
        if useChips(options) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(options, id: \.self) { option in
                    Chip(title: label(for: option),
                         selected: isSelected(option),
                         multi: multi) { toggle(option) }
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    OptionRow(title: label(for: option),
                              selected: isSelected(option),
                              multi: multi) { toggle(option) }
                }
            }
        }
    }

    @ViewBuilder
    private func scaleControl(_ field: InputField) -> some View {
        let lower = field.min ?? 0
        let upper = max(field.max ?? 10, lower + (field.step ?? 1))
        let step = field.step ?? 1
        if isSmallIntegerScale(lower: lower, upper: upper, step: step) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(Array(stride(from: lower, through: upper, by: step)), id: \.self) { value in
                    Chip(title: scaleLabel(value, field),
                         selected: scaleValue[field.id] == value) {
                        scaleValue[field.id] = value
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                HStack {
                    Text(formatted(scaleValue[field.id] ?? lower, field))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(scaleValue[field.id] == nil ? .secondary : .primary)
                    Spacer()
                }
                Slider(value: Binding(get: { scaleValue[field.id] ?? lower },
                                      set: { scaleValue[field.id] = $0 }),
                       in: lower...upper, step: step)
            }
        }
    }

    private func numberControl(_ field: InputField) -> some View {
        HStack(spacing: 8) {
            TextField(field.placeholder ?? "Enter a number",
                      text: customBinding(field))
                .keyboardType(.decimalPad)
            if let unit = field.unit, !unit.isEmpty {
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func textField(_ field: InputField, placeholder: String) -> some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: customBinding(field), axis: .vertical)
                .lineLimit(1...4)
            Button {
                presentVoice { transcript in
                    let existing = customText[field.id] ?? ""
                    customText[field.id] = existing.isEmpty ? transcript : existing + " " + transcript
                }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speak")
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func blockStatusControl() -> some View {
        let blocks = store.today.blocks
        if blocks.isEmpty {
            Text("No blocks scheduled today.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(blocks) { block in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(block.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(block.timeRangeLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        HStack(spacing: 6) {
                            ForEach([BlockStatus.done, .missed, .skipped], id: \.rawValue) { status in
                                StatusPip(status: status,
                                          selected: blockChoice[block.id] == status) {
                                    blockChoice[block.id] = status
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    // MARK: - Bindings & helpers

    private func customBinding(_ field: InputField) -> Binding<String> {
        Binding(get: { customText[field.id] ?? "" }, set: { customText[field.id] = $0 })
    }

    private func dateBinding(_ field: InputField) -> Binding<Date> {
        Binding(get: { dateValue[field.id] ?? Date() }, set: { dateValue[field.id] = $0 })
    }

    private func optionsWithOther(_ field: InputField) -> [String] {
        field.allowCustom ? field.options + [Self.otherMarker] : field.options
    }

    private func label(for option: String) -> String {
        option == Self.otherMarker ? "Other…" : option
    }

    private func useChips(_ options: [String]) -> Bool {
        let longest = options.map { label(for: $0).count }.max() ?? 0
        return longest <= 14 && options.count <= 8
    }

    private func isSmallIntegerScale(lower: Double, upper: Double, step: Double) -> Bool {
        guard step > 0 else { return false }
        let integral = lower == lower.rounded() && upper == upper.rounded() && step == step.rounded()
        return integral && (upper - lower) / step <= 10
    }

    private func applyBlockStatuses() {
        for block in store.today.blocks {
            if let status = blockChoice[block.id] {
                store.setBlockStatus(blockID: block.id, dateKey: store.todayKey, status: status)
            }
        }
    }

    // MARK: - Answer assembly

    private var hasAnswer: Bool {
        request.fields.contains { field in
            if field.type == .blockStatus {
                return store.today.blocks.contains { blockChoice[$0.id] != nil }
            }
            return !valueString(for: field).isEmpty
        }
    }

    private func summary() -> String {
        var lines: [String] = []
        for field in request.fields {
            if field.type == .blockStatus {
                let blockLines = store.today.blocks.compactMap { block -> String? in
                    guard let status = blockChoice[block.id] else { return nil }
                    return "• \(block.title): \(status.label)"
                }
                if !blockLines.isEmpty {
                    lines.append("Block check-in:")
                    lines.append(contentsOf: blockLines)
                }
            } else {
                let value = valueString(for: field)
                if !value.isEmpty { lines.append("\(field.label): \(value)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func valueString(for field: InputField) -> String {
        switch field.type {
        case .singleSelect:
            if singleChoice[field.id] == Self.otherMarker {
                return (customText[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return singleChoice[field.id] ?? ""
        case .multiSelect:
            var picks = (multiChoice[field.id] ?? []).sorted()
            let custom = (customText[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { picks.append(custom) }
            return picks.joined(separator: ", ")
        case .scale:
            guard let value = scaleValue[field.id] else { return "" }
            return formatted(value, field)
        case .number:
            let text = (customText[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "" }
            if let unit = field.unit, !unit.isEmpty { return "\(text) \(unit)" }
            return text
        case .time:
            guard let date = dateValue[field.id] else { return "" }
            return date.formatted(date: .omitted, time: .shortened)
        case .date:
            guard let date = dateValue[field.id] else { return "" }
            return date.formatted(date: .abbreviated, time: .omitted)
        case .boolean:
            guard let value = boolValue[field.id] else { return "" }
            return value ? "Yes" : "No"
        case .text:
            return (customText[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .blockStatus:
            return ""
        }
    }

    private func scaleLabel(_ value: Double, _ field: InputField) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func formatted(_ value: Double, _ field: InputField) -> String {
        let step = field.step ?? 1
        let number = step.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
        if let unit = field.unit, !unit.isEmpty { return "\(number) \(unit)" }
        return number
    }
}

// MARK: - Pieces

private struct Chip: View {
    let title: String
    let selected: Bool
    var multi: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if multi {
                    Image(systemName: selected ? "checkmark" : "plus")
                        .font(.caption2.weight(.bold))
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 15)
            .background(selected ? Color.accentColor : Color(.tertiarySystemBackground),
                        in: Capsule())
            .foregroundStyle(selected ? .white : .primary)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.08)))
        }
        .buttonStyle(.plain)
    }
}

private struct OptionRow: View {
    let title: String
    let selected: Bool
    let multi: Bool
    let action: () -> Void

    private var icon: String {
        if multi { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(selected ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

private struct StatusPip: View {
    let status: BlockStatus
    let selected: Bool
    let action: () -> Void

    private var icon: String {
        switch status {
        case .done: return "checkmark"
        case .missed: return "xmark"
        case .skipped: return "forward.fill"
        default: return "circle"
        }
    }

    private var tint: Color {
        switch status {
        case .done: return .green
        case .missed: return .red
        case .skipped: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 34, height: 34)
                .background(selected ? tint : Color(.systemFill), in: Circle())
                .foregroundStyle(selected ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.label)
    }
}

/// Wraps subviews left-to-right, moving to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let frames = frames(for: subviews, maxWidth: maxWidth)
        let width = proposal.width ?? (frames.map { $0.maxX }.max() ?? 0)
        let height = frames.map { $0.maxY }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(for: subviews, maxWidth: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let frame = frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func frames(for subviews: Subviews, maxWidth: CGFloat) -> [CGRect] {
        var result: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let width = min(size.width, maxWidth)
            if x > 0 && x + width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            result.append(CGRect(x: x, y: y, width: width, height: size.height))
            x += width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return result
    }
}
