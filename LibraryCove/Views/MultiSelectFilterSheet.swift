import SwiftUI

/// Searchable multi-select filter over plain strings, organized into named
/// sections (e.g. authors and tags). Each section shows its currently
/// selected values with a per-section clear button, an "All" row, and the
/// search-filtered list of every available value — tap to toggle checkboxes.
/// Selection commits only via the toolbar Done button (Cancel discards).
struct MultiSelectFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let searchTextPlaceholder: String
    let sections: [FilterSection]

    struct FilterSection: Identifiable {
        let title: String
        let items: [String]
        /// Committed selection when the sheet was opened.
        let selection: Set<String>
        let onChange: (Set<String>) -> Void

        var id: String { title }
    }

    @State private var selections: [String: Set<String>] = [:]
    @State private var searchText = ""

    init(searchTextPlaceholder: String, sections: [FilterSection]) {
        self.searchTextPlaceholder = searchTextPlaceholder
        self.sections = sections
        _selections = State(initialValue: Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.selection) }))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(searchTextPlaceholder, text: $searchText)
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
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        for section in sections {
                            section.onChange(selections[section.id] ?? [])
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: FilterSection) -> some View {
        let selected = selections[section.id] ?? []
        let selectedSorted = selected.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selectedShown = selectedSorted.filter(matching: searchText)
        let itemMatches = section.items.filter(matching: searchText)
        // While searching, a section only appears if something matches it;
        // otherwise it shows whenever it holds anything at all.
        let showSection = searching
            ? (!selectedShown.isEmpty || !itemMatches.isEmpty)
            : (!section.items.isEmpty || !selected.isEmpty)

        if showSection {
            Section(section.title) {
                if !selectedShown.isEmpty {
                    ForEach(selectedShown, id: \.self) { value in
                        row(value, section: section, isOn: true)
                    }
                    Button("Clear \(section.title.lowercased())", role: .destructive) {
                        selections[section.id] = []
                    }
                }
                if !searching {
                    Button {
                        selections[section.id] = []
                    } label: {
                        HStack {
                            Text("All")
                            Spacer()
                            if selected.isEmpty {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if !itemMatches.isEmpty {
                    ForEach(itemMatches, id: \.self) { value in
                        row(value, section: section, isOn: selected.contains(value))
                    }
                }
            }
        }
    }

    private func row(_ value: String, section: FilterSection, isOn: Bool) -> some View {
        Button {
            var updated = selections[section.id] ?? []
            if updated.contains(value) {
                updated.remove(value)
            } else {
                updated.insert(value)
            }
            selections[section.id] = updated
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

private extension Sequence where Element == String {
    /// Case-insensitive whole-string containment; empty query matches all.
    func filter(matching query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(self) }
        return filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}
