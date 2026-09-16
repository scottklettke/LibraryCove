import SwiftUI

/// Manual multi-select editor for tags on one or more books.
/// Searchable, with a "New value…" field so users can create a tag
/// inline (no AI involved). The checked set becomes the assigned set for every
/// target book when Done is pressed; Cancel discards.
struct AssignValuesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// Lowercase label used in prompts ("shelf" / "tag").
    let valueLabel: String
    let knownValues: [String]
    /// The current values across the targeted book(s) — pre-checked.
    let initialValues: Set<String>
    let onDone: (Set<String>) -> Void

    @State private var selection: Set<String>
    @State private var searchText = ""
    @State private var newValue = ""

    init(title: String, valueLabel: String, knownValues: [String],
         initialValues: Set<String>, onDone: @escaping (Set<String>) -> Void) {
        self.title = title
        self.valueLabel = valueLabel
        self.knownValues = knownValues
        self.initialValues = initialValues
        self.onDone = onDone
        _selection = State(initialValue: initialValues)
    }

    private var filteredKnown: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = Set(knownValues).subtracting(selection)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !query.isEmpty else { return base }
        return base.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var selectedSorted: [String] {
        selection.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func addNew() {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selection.insert(trimmed)
        newValue = ""
    }

    private func toggle(_ value: String) {
        if selection.contains(value) {
            selection.remove(value)
        } else {
            selection.insert(value)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search \(valueLabel)s", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("New \(valueLabel)…", text: $newValue)
                            .textInputAutocapitalization(.words)
                            .onSubmit(addNew)
                        Button("Add") { addNew() }
                            .disabled(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Create a new \(valueLabel)")
                        .textCase(nil)
                }
                if !selectedSorted.isEmpty {
                    Section("Selected") {
                        ForEach(selectedSorted, id: \.self) { value in
                            row(value)
                        }
                        Button("Clear all") {
                            selection = []
                        }
                    }
                }
                Section {
                    ForEach(filteredKnown, id: \.self) { value in
                        row(value)
                    }
                } header: {
                    Text("\(valueLabel.capitalized)es — tap to toggle")
                        .textCase(nil)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(selection)
                        dismiss()
                    }
                }
            }
        }
    }

    private func row(_ value: String) -> some View {
        let isOn = selection.contains(value)
        return Button {
            toggle(value)
        } label: {
            HStack {
                Text(value)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color(uiColor: .secondaryLabel))
            }
        }
    }
}
