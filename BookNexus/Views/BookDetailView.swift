import SwiftUI
import SwiftData
import UIKit

/// Detail view for a single book: info, notes, edit.
struct BookDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let book: Book
    /// Members — used to resolve the "Added by" name.
    @Query private var users: [User]

    @State private var showEdit = false
    @State private var newNoteText = ""
    @State private var isFetchingDescription = false
    @State private var fetchError: String?

    var body: some View {
        List {
            headerSection
            infoSection
            copiesSection
            notesSection
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEdit = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            NavigationStack {
                BookFormView(catalog: nil, existing: book, onDeleted: {
                    showEdit = false
                    dismiss()
                })
            }
        }
    }

    private var copiesSection: some View {
        let copies = allCopiesIncludingCurrent
        guard copies.count > 1 else { return AnyView(EmptyView()) }
        return AnyView(
            Section {
                ForEach(Array(copies.enumerated()), id: \.offset) { index, copy in
                    NavigationLink {
                        BookDetailView(book: copy)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(copy.physicalLocation ?? "Unplaced")
                                    .foregroundStyle(copy.physicalLocation == nil ? .secondary : .primary)
                                if copy.id == book.id {
                                    Text("(this copy)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            if copy.isLoaned {
                                Label(copy.loanedTo ?? "Loaned out", systemImage: "person.fill")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            } else {
                                Text(copy.statusEnum.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Copies")
            } footer: {
                Text("Every copy of this title, with its location and loan status. Open a copy to view or manage it.")
            }
        )
    }

    /// Every copy of the current book's title: normalized-ISBN siblings, or
    /// title-matched when there's no ISBN, plus the current copy itself.
    private var allCopiesIncludingCurrent: [Book] {
        let all = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
        var copies = BookMastering.otherCopies(of: book, in: all)
        copies.append(book)
        return copies.sorted { $0.createdAt < $1.createdAt }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                AsyncCoverView(url: CoverImageStore.displayURL(forCover: book.coverImageURL), width: 84, height: 124)
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.headline)
                    Text(book.authorsText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let year = book.publicationYear {
                        Text(verbatim: "\(year)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { value in
                            Image(systemName: (book.rating ?? 0) >= value ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle((book.rating ?? 0) >= value ? .yellow : Color(uiColor: .tertiaryLabel))
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private var infoSection: some View {
            Section("Details") {
                LabeledContent("Status", value: book.statusEnum.displayName)
                LabeledContent("Type", value: (BookKind(rawValue: book.kind).flatMap { $0 == .notSet ? nil : $0 }?.displayName) ?? "Not set")
                LabeledContent("Date added", value: addedDateFormatter.string(from: book.createdAt))
                LabeledContent("Added by", value: addedByName)
            if let location = book.physicalLocation, !location.isEmpty {
                LabeledContent("Location", value: location)
            }
            if let publisher = book.publisher {
                LabeledContent("Publisher", value: publisher)
            }
            if let pageCount = book.pageCount {
                LabeledContent("Pages", value: "\(pageCount)")
            }
            if let isbn = book.isbn {
                LabeledContent("ISBN", value: isbn)
            }
            if !book.tags.isEmpty {
                LabeledContent("Tags", value: book.tags.joined(separator: ", "))
            }
            if !book.shelves.isEmpty {
                LabeledContent("Shelves", value: book.shelves.joined(separator: ", "))
            }
            if let description = book.bookDescription {
                Text(description)
                    .font(.body)
                if let source = book.descriptionSource, source != "none" {
                    LabeledContent("Source", value: DescriptionSource.label(for: source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    if isFetchingDescription {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        Task { await fetchDescription() }
                    } label: {
                        Text(isFetchingDescription ? "Fetching…" : "Fetch description")
                    }
                    .disabled(isFetchingDescription)
                }
                if let fetchError {
                    Text(fetchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            let notes = book.notes ?? []
            if notes.isEmpty {
                Text("No notes yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notes.sorted { $0.createdAt < $1.createdAt }) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.content)
                            .font(.body)
                        if let reference = note.pageReference {
                            Text("p. \(reference)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                TextField("Add a note…", text: $newNoteText)
                    .textInputAutocapitalization(.sentences)
                Button {
                    addNote()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addNote() {
        let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let note = Note(book: book, userID: "", title: "", content: text)
        modelContext.insert(note)
        try? modelContext.save()
        newNoteText = ""
    }
    private func fetchDescription() async {
        isFetchingDescription = true
        fetchError = nil
        defer { isFetchingDescription = false }

        let catalog = OpenLibraryService()
        let result: CatalogBook?
        if let isbn = book.isbn {
            result = try? await catalog.lookup(isbn: isbn, preferred: .openlibrary)
        } else {
            let results = (try? await catalog.search(query: book.title, preferred: .openlibrary)) ?? []
            result = results.first
        }

        guard let found = result, let description = found.description, !description.isEmpty else {
            fetchError = "No description found for this book."
            return
        }

        book.bookDescription = description
        book.descriptionSource = found.descriptionSource
        book.updatedAt = Date()
        try? modelContext.save()
    }

    private var addedByName: String {
        if let id = book.ownerID, let owner = users.first(where: { $0.id == id }) {
            return owner.displayName
        }
        // Books without an owner fall back to the signed-in library member.
        return users.first(where: \.isActive)?.displayName ?? "—"
    }

    private var addedDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}