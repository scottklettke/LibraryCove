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

    @State private var isSummarizing = false
    @State private var showSummarySheet = false
    @State private var summaryText = ""
    @State private var summaryCopied = false
    @State private var summaryError: String?
    @State private var showSummaryError = false
    @State private var isImprovingDescription = false
    @State private var improveError: String?
    @State private var showImproveError = false

    var body: some View {
        List {
            headerSection
            infoSection
            summarySection
            copiesSection
            notesSection
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await summarize() }
                    } label: {
                        Label("Summarize", systemImage: "wand.and.stars")
                    }
                    .disabled(isSummarizing)
                    Button {
                        Task { await improveDescription() }
                    } label: {
                        Label(
                            isImprovingDescription ? "Improving…" : "Improve description",
                            systemImage: "text.quote"
                        )
                    }
                    .disabled(!canImproveDescription || book.hasImprovedDescription || isImprovingDescription)
                    if book.hasImprovedDescription {
                        Button {
                            restoreOriginalDescription()
                        } label: {
                            Label("Restore original description", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isImprovingDescription)
                    }
                } label: {
                    if isSummarizing || isImprovingDescription {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("AI", systemImage: "sparkles")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEdit = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showSummarySheet) {
            NavigationStack {
                ScrollView {
                    Text(summaryText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Summary")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            showSummarySheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            UIPasteboard.general.string = summaryText
                            summaryCopied = true
                        } label: {
                            Label(summaryCopied ? "Copied" : "Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
        .alert("AI Summary", isPresented: $showSummaryError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(summaryError ?? "")
        }
        .alert("Improve Description", isPresented: $showImproveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(improveError ?? "")
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
                if book.hasImprovedDescription {
                    HStack(spacing: 8) {
                        Label("AI generated", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore original") {
                            restoreOriginalDescription()
                        }
                        .font(.caption)
                    }
                }
                if let source = book.descriptionSource, source != "none" {
                    LabeledContent("Source", value: sourceLabel(source))
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

    private var summarySection: some View {
        if let summary = book.summary, !summary.isEmpty {
            return AnyView(
                Section("Summary") {
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                    Label("AI generated", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            )
        }
        return AnyView(EmptyView())
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

    private func summarize() async {
        guard let description = book.bookDescription,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summaryError = "This book has no description yet. Fetch one in the Details section before summarizing."
            showSummaryError = true
            return
        }

        isSummarizing = true
        defer { isSummarizing = false }

        do {
            let result = try await AIService.shared.generate(
                AIPrompt(user: "Summarize this book description in 2-3 sentences:\n\(description)")
            )
            summaryText = result.text
            summaryCopied = false
            // Keep the generated summary in its own field (shown in the Summary
            // section and searchable via the AI catalog) instead of overwriting
            // the book description.
            book.summary = result.text
            book.updatedAt = Date()
            try? modelContext.save()
            showSummarySheet = true
        } catch let error as AIError {
            switch error {
            case .notConfigured:
                summaryError = "Set up your AI endpoint in Settings → AI to use this."
            default:
                summaryError = "The AI summary couldn't be generated: \(error.localizedDescription)"
            }
            showSummaryError = true
        } catch {
            summaryError = "The AI summary couldn't be generated: \(error.localizedDescription)"
            showSummaryError = true
        }
    }

    /// "Improve description" needs either an existing description to rewrite
    /// or an ISBN to fetch richer source text from the catalog.
    private var canImproveDescription: Bool {
        book.bookDescription != nil || book.isbn != nil
    }

    private func restoreOriginalDescription() {
        AIDescriptionImprovement.revert(to: book)
        try? modelContext.save()
    }

    private func improveDescription() async {
        guard canImproveDescription else { return }

        isImprovingDescription = true
        defer { isImprovingDescription = false }

        do {
            let (raw, source) = await AIDescriptionImprovement.onlineText(for: book)
            let rewritten = try await AIService.shared.generate(
                AIDescriptionImprovement.prompt(raw: raw)
            )
            AIDescriptionImprovement.apply(rewritten.text, source: source, to: book)
            try? modelContext.save()
        } catch let error as AIError {
            switch error {
            case .notConfigured, .engineUnavailable:
                improveError = "Set up an AI engine in Settings → AI first."
            default:
                improveError = error.localizedDescription
            }
            showImproveError = true
        } catch {
            improveError = error.localizedDescription
            showImproveError = true
        }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "wikipedia": return "Wikipedia"
        case "googlebooks": return "Google Books"
        case "openlibrary": return "Open Library"
        default: return source
        }
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