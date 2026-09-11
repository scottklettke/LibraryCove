import SwiftUI
import SwiftData

/// Lets the user pick WHICH copy of a multi-copy title to delete. Copies are
/// listed by the date they were added (newest first), each row showing the
/// added date plus its location/loan status so the copies are
/// distinguishable. Tapping a row deletes that copy via `onDelete`.
struct CopyDeletePicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// All copies of the title, any order — sorted here by added date.
    let copies: [Book]
    /// The copy the user was looking at when delete was pressed (marked in
    /// the list; optional).
    var currentBookID: String? = nil
    /// Called with the chosen copy. Perform the deletion here.
    let onDelete: (Book) -> Void

    private var sortedCopies: [Book] {
        copies.sorted { ($0.acquiredDate ?? $0.createdAt) > ($1.acquiredDate ?? $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sortedCopies, id: \.id) { copy in
                        Button {
                            onDelete(copy)
                            dismiss()
                        } label: {
                            row(for: copy)
                        }
                    }
                } header: {
                    Text("Which copy?")
                } footer: {
                    Text("Copies are listed by the date they were added, newest first. Deleting removes only the copy you pick — the others stay in your library.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for copy: Book) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Added \(dateText(for: copy))")
                    .font(.body)
                if copy.id == currentBookID {
                    Text("(this one)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            let details = copyDetails(for: copy)
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyDetails(for copy: Book) -> [String] {
        var details: [String] = []
        if let location = copy.physicalLocation, !location.isEmpty {
            details.append(location)
        }
        if let loanedTo = copy.loanedTo, !loanedTo.isEmpty {
            details.append("loaned to \(loanedTo)")
        }
        return details
    }

    private func dateText(for copy: Book) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: copy.acquiredDate ?? copy.createdAt)
    }
}
