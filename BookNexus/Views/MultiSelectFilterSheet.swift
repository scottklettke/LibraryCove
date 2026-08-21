import SwiftUI

/// Searchable multi-select filter over a list of plain strings (authors, tags).
/// Shows a search field at the top, the currently selected items grouped at
/// the top with a clear button, then an "All" row and the search-filtered list
/// of every available item — tap one or more checkboxes. Selection commits
/// only via the toolbar Done button (Cancel discards).
struct MultiSelectFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let items: [String]
    /// Committed selection when Done is pressed.
    let onDone: (Set<String>) -> Void

    @State private var selection: Set<String>
    @State private var searchText = ""

    init(title: String, items: [String], selection: Set<String>, onDone: @escaping (Set<String>) -> Void) {
        self.title = title
        self.items = items
        self.onDone = onDone
        _selection = State(initialValue: selection)
    }

    private var filteredResults: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = items.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !query.isEmpty else { return base }
        return base.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var selectedSorted: [String] {
        selection.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
                    TextField("Search \(title.lowercased())", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !selectedSorted.isEmpty {
                    Section("Selected") {
                        ForEach(selectedSorted, id: \.self) { value in
                            filterRow(value)
                        }
                        Button("Clear selection", role: .destructive) {
                            selection = []
                        }
                    }
                }
                Section {
                    Button {
                        selection = []
                    } label: {
                        HStack {
                            Text("All")
                            Spacer()
                            if selection.isEmpty {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Section {
                    ForEach(filteredResults, id: \.self) { value in
                        filterRow(value)
                    }
                } header: {
                    Text("\(title) — tap to select multiple")
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

    private func filterRow(_ value: String) -> some View {
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
