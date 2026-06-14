import SwiftUI

/// Renders the coach's `request_user_input` spec as native controls and turns the
/// answers into a readable message. The compose dock's text field stays available
/// as a fallback regardless of what this shows.
struct StructuredInputView: View {
    let request: InputRequest
    var disabled: Bool
    var onSubmit: (String) -> Void

    private static let otherMarker = "\u{2063}other"

    @State private var singleChoice: [UUID: String] = [:]
    @State private var multiChoice: [UUID: Set<String>] = [:]
    @State private var customText: [UUID: String] = [:]
    @State private var scaleValue: [UUID: Double] = [:]
    @State private var boolValue: [UUID: Bool] = [:]
    @State private var dateValue: [UUID: Date] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let prompt = request.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.subheadline.weight(.semibold))
            }
            ForEach(request.fields) { field in
                VStack(alignment: .leading, spacing: 8) {
                    if request.fields.count > 1 || request.prompt?.isEmpty == false {
                        Text(field.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    fieldControl(field)
                }
            }
            Button {
                onSubmit(summary())
            } label: {
                Text(request.submitLabel ?? "Send")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled || !hasAnswer)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground),
                   in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
    }

    // MARK: - Controls

    @ViewBuilder
    private func fieldControl(_ field: InputField) -> some View {
        switch field.type {
        case .singleSelect:
            chips(field, options: optionsWithOther(field)) { option in
                singleChoice[field.id] == option
            } toggle: { option in
                singleChoice[field.id] = option
            }
            if singleChoice[field.id] == Self.otherMarker {
                customField(field, placeholder: "Type your answer")
            }

        case .multiSelect:
            chips(field, options: field.options) { option in
                multiChoice[field.id, default: []].contains(option)
            } toggle: { option in
                var set = multiChoice[field.id, default: []]
                if set.contains(option) { set.remove(option) } else { set.insert(option) }
                multiChoice[field.id] = set
            }
            if field.allowCustom {
                customField(field, placeholder: "Add another…")
            }

        case .scale:
            let lower = field.min ?? 0
            let upper = field.max ?? 10
            let step = field.step ?? 1
            let value = scaleValue[field.id] ?? lower
            VStack(spacing: 4) {
                HStack {
                    Text(formatted(value, field))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                Slider(value: Binding(
                    get: { scaleValue[field.id] ?? lower },
                    set: { scaleValue[field.id] = $0 }
                ), in: lower...max(upper, lower + step), step: step)
            }

        case .number:
            HStack {
                TextField(field.placeholder ?? "Enter a number",
                          text: Binding(get: { customText[field.id] ?? "" },
                                        set: { customText[field.id] = $0 }))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                if let unit = field.unit, !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary)
                }
            }

        case .time:
            DatePicker("", selection: Binding(
                get: { dateValue[field.id] ?? Date() },
                set: { dateValue[field.id] = $0 }
            ), displayedComponents: .hourAndMinute)
                .labelsHidden()

        case .date:
            DatePicker("", selection: Binding(
                get: { dateValue[field.id] ?? Date() },
                set: { dateValue[field.id] = $0 }
            ), displayedComponents: .date)
                .labelsHidden()

        case .boolean:
            Toggle(isOn: Binding(
                get: { boolValue[field.id] ?? false },
                set: { boolValue[field.id] = $0 }
            )) {
                Text(boolValue[field.id] == true ? "Yes" : "No")
                    .foregroundStyle(.secondary)
            }

        case .text:
            customField(field, placeholder: field.placeholder ?? "Type your answer")
        }
    }

    private func customField(_ field: InputField, placeholder: String) -> some View {
        TextField(placeholder, text: Binding(
            get: { customText[field.id] ?? "" },
            set: { customText[field.id] = $0 }
        ), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
    }

    private func chips(_ field: InputField,
                       options: [String],
                       isSelected: @escaping (String) -> Bool,
                       toggle: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                let selected = isSelected(option)
                Button {
                    toggle(option)
                } label: {
                    Text(option == Self.otherMarker ? "Other…" : option)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(selected ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: Capsule())
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func optionsWithOther(_ field: InputField) -> [String] {
        field.allowCustom ? field.options + [Self.otherMarker] : field.options
    }

    // MARK: - Answer assembly

    private var hasAnswer: Bool {
        request.fields.contains { fieldAnswered($0) }
    }

    private func fieldAnswered(_ field: InputField) -> Bool {
        !valueString(for: field).isEmpty
    }

    private func summary() -> String {
        let lines = request.fields.compactMap { field -> String? in
            let value = valueString(for: field)
            guard !value.isEmpty else { return nil }
            return "\(field.label): \(value)"
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
        }
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
