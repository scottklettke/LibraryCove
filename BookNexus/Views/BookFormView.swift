import SwiftUI
import SwiftData

/// Import a catalog result into the library.
struct BookImportView: View {
    let catalog: CatalogBook

    var body: some View {
        BookFormView(catalog: catalog, existing: nil)
            .navigationTitle("Import book")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shared form to create (from catalog or blank) or edit a Book.
struct BookFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let catalog: CatalogBook?
    var existing: Book?
    var onSaved: () -> Void = {}
    var dismissOnSave: Bool = true

    @State private var title = ""
    @State private var authorsText = ""
    @State private var yearText = ""
    @State private var genresText = ""
    @State private var publisherText = ""
    @State private var pageCountText = ""
    @State private var description = ""
    @State private var locationText = ""
    @State private var status: BookStatus = .toRead
    @State private var rating: Int?
    @State private var coverURLs: [String] = []
    @State private var selectedCover: String?
    @State private var locationStore = LocationStore()
    @State private var genreStore = GenreStore()
    @State private var genreQuery = ""
    @State private var loanedToText = ""
    @State private var loanedDate: Date?
    @State private var descriptionSource: DescriptionSource = .openlibrary
    @State private var isFetchingDescription = false
    @State private var fetchError: String?
    @State private var showDuplicateAlert = false
    @State private var pendingInsertBook: Book?

    init(catalog: CatalogBook? = nil, existing: Book? = nil, onSaved: @escaping () -> Void = {}, dismissOnSave: Bool = true) {
        self.catalog = catalog
        self.existing = existing
        self.onSaved = onSaved
        self.dismissOnSave = dismissOnSave
        _status = State(initialValue: existing?.statusEnum ?? .toRead)
        _rating = State(initialValue: existing?.rating)

        if let catalog {
            _title = State(initialValue: catalog.title)
            _authorsText = State(initialValue: catalog.authors.joined(separator: ", "))
            _yearText = State(initialValue: catalog.publicationYear.map { String($0) } ?? "")
            _genresText = State(initialValue: "")
            _publisherText = State(initialValue: catalog.publisher ?? "")
            _pageCountText = State(initialValue: catalog.pageCount.map { String($0) } ?? "")
            _description = State(initialValue: catalog.description ?? "")
            _coverURLs = State(initialValue: catalog.coverURLs)
            _selectedCover = State(initialValue: catalog.primaryCoverURL)
        } else if let existing {
            _title = State(initialValue: existing.title)
            _authorsText = State(initialValue: existing.authors.joined(separator: ", "))
            _yearText = State(initialValue: existing.publicationYear.map { String($0) } ?? "")
            _genresText = State(initialValue: existing.genres.joined(separator: ", "))
            _publisherText = State(initialValue: existing.publisher ?? "")
            _pageCountText = State(initialValue: existing.pageCount.map { String($0) } ?? "")
            _description = State(initialValue: existing.bookDescription ?? "")
            _locationText = State(initialValue: existing.physicalLocation ?? "")
            _coverURLs = State(initialValue: existing.coverImageURL.map { [$0] } ?? [])
            _selectedCover = State(initialValue: existing.coverImageURL)
        }
    }

    var body: some View {
        Form {
            coverSection
            detailsSection
            statusSection
            descriptionSection
            if existing != nil {
                loanedSection
            }
            saveSection
        }
        .task {
            if catalog != nil && description.isEmpty {
                await fetchDescription()
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if existing != nil {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert("This book is already in your library", isPresented: $showDuplicateAlert) {
            Button("Add another copy") {
                if let pending = pendingInsertBook {
                    modelContext.insert(pending)
                    try? modelContext.save()
                    onSaved()
                    if dismissOnSave {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingInsertBook = nil
            }
        } message: {
            Text("You already have this book. You can add another copy with a different location, or cancel.")
        }
    }

    private var coverSection: some View {
        Section {
            if !coverURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(coverURLs, id: \.self) { url in
                            Button {
                                selectedCover = url
                            } label: {
                                AsyncCoverView(url: URL(string: url), width: 68, height: 100)
                                    .overlay(alignment: .bottomTrailing) {
                                        if selectedCover == url {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.blue)
                                                .padding(4)
            }
        }
    }

                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Cover")
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("Title *", text: $title)
            TextField("Authors (comma separated)", text: $authorsText)
                .textInputAutocapitalization(.words)
            LabeledContent("Published year") {
                TextField("Published year", text: $yearText)
                    .keyboardType(.numberPad)
            }
            LabeledContent("Pages in book") {
                TextField("Pages in book", text: $pageCountText)
                    .keyboardType(.numberPad)
            }
            TextField("Publisher", text: $publisherText)
                .textInputAutocapitalization(.words)
            genrePicker
            if let isbn = catalog?.isbn ?? existing?.isbn {
                LabeledContent("ISBN", value: isbn)
                if let existing {
                    LabeledContent("Date added", value: addedDateFormatter.string(from: existing.createdAt))
                }
            }
        } header: {
            Text("Details")
        } footer: {
            Text("Fields marked * are required.")
        }
    }

    private var genrePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !selectedGenres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selectedGenres, id: \.self) { genre in
                            Button {
                                toggleGenre(genre)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(genre)
                                        .font(.caption)
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
            }
        }
    }

            }
            HStack {
                TextField("Add your own category…", text: $genreQuery)
                    .textInputAutocapitalization(.words)
                    .onSubmit {
                        addGenre(genreQuery)
                        genreQuery = ""
                    }
                Menu {
                    ForEach(genreStore.genres, id: \.self) { genre in
                        Button {
                            toggleGenre(genre)
                        } label: {
                            if selectedGenres.contains(where: {
                                $0.caseInsensitiveCompare(genre) == .orderedSame
                            }) {
                                Label(genre, systemImage: "checkmark")
                            } else {
                                Text(genre)
            }
        }
    }

                    Button("Add new category") {
                        addGenre(genreQuery)
                        genreQuery = ""
                    }
                } label: {
                    Label("Pick", systemImage: "tag")
                }
            }
        }
    }

    private var statusSection: some View {
        Section {
            Picker("Status", selection: $status) {
                ForEach(BookStatus.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            LabeledContent("Rating") {
                RatingPicker(rating: $rating)
            }
            HStack {
                TextField("Location", text: $locationText)
                    .textInputAutocapitalization(.words)
                Menu {
                    ForEach(locationStore.locations, id: \.self) { loc in
                        Button(loc) { locationText = loc }
                    }
                    if !locationText.isEmpty {
                        Button("Add New") {
                            let added = locationStore.add(locationText)
                            locationText = added
                        }
                        Button("Clear") { locationText = "" }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.callout)
                }
            }
        } header: {
            Text("Status & notes")
        }
    }

    private var loanedSection: some View {
        Section {
            TextField("Person loaned to", text: $loanedToText)
                .textInputAutocapitalization(.words)
            if let loanedDate {
                DatePicker("Loaned on", selection: Binding(
                    get: { loanedDate },
                    set: { self.loanedDate = $0 }
                ), displayedComponents: .date)
            } else {
                Button("Mark loaned today") {
                    loanedDate = Date()
                }
            }
            if loanedToText.isEmpty && loanedDate == nil {
                Text("No book is currently loaned out.")
                    .foregroundStyle(.secondary)
            }
            Button("Returned") {
                loanedToText = ""
                loanedDate = nil
            }
            .disabled(loanedToText.isEmpty && loanedDate == nil)
        } header: {
            Text("Loaned")
        }
    }

    private var locationPicker: some View {
        Group {
            Picker("Location", selection: $locationText) {
                Text("—").tag("")
                ForEach(locationStore.locations, id: \.self) { loc in
                    Text(loc).tag(loc)
                }
                Text("New location…").tag("__new__")
            }
            TextField("Or type a new location", text: $locationText)
        }
    }

    private var descriptionSection: some View {
        Section {
            Picker("Source", selection: $descriptionSource) {
                ForEach(DescriptionSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            TextEditor(text: $description)
                .frame(minHeight: 120)
            if isFetchingDescription {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching description…")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button {
                    Task { await fetchDescription() }
                } label: {
                    Text(isFetchingDescription ? "Fetching…" : "Fetch description")
                }
                .disabled(isFetchingDescription)
                if !description.isEmpty {
                    Button(role: .destructive) {
                        description = ""
                    } label: {
                        Text("Delete description")
                    }
                }
            }
            if let fetchError {
                Text(fetchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Description")
        } footer: {
            Text("A short summary of the book. Fetched automatically from the ISBN lookup when available.")
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    Text(existing == nil ? "Add to library" : "Save changes")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
        }
    }

    private func fetchDescription() async {
        isFetchingDescription = true
        fetchError = nil
        defer { isFetchingDescription = false }

        let catalog = OpenLibraryService()
        let result: CatalogBook?
        let isbn = catalogISBN
        if let isbn {
            result = try? await catalog.lookup(isbn: isbn, preferred: descriptionSource)
        } else if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let results = (try? await catalog.search(query: title, preferred: descriptionSource)) ?? []
            result = results.first
        } else {
            result = nil
        }

        guard let found = result, let newDescription = found.description, !newDescription.isEmpty else {
            fetchError = "No description found for this book."
            return
        }

        description = newDescription
    }

    private var catalogISBN: String? {
        if let isbn = catalog?.isbn { return isbn }
        return existing?.isbn
    }

    private var selectedGenres: [String] {
        genresText.split(separator: ",").map(String.init).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func toggleGenre(_ genre: String) {
        if selectedGenres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) {
            removeGenre(genre)
        } else {
            addGenre(genre)
        }
    }

    private func addGenre(_ genre: String) {
        let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let canonical = genreStore.add(trimmed)
        var list = selectedGenres
        if !list.contains(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) {
            list.append(canonical)
        }
        genresText = list.joined(separator: ", ")
    }

    private func removeGenre(_ genre: String) {
        let list = selectedGenres.filter { $0.caseInsensitiveCompare(genre) != .orderedSame }
        genresText = list.joined(separator: ", ")
    }

    private var addedDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let authors = authorsText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let genres = genresText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let year = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        let pageCount = Int(pageCountText.trimmingCharacters(in: .whitespacesAndNewlines))
        let location = locationText == "__new__" ? "" : locationText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty {
            locationStore.add(location)
        }

        let cover = selectedCover ?? existing?.coverImageURL

        if let existing {
            existing.title = trimmedTitle
            existing.authors = authors
            existing.publicationYear = year
            existing.genres = genres
            existing.publisher = publisherText.isEmpty ? nil : publisherText
            existing.pageCount = pageCount
            existing.bookDescription = description.isEmpty ? nil : description
            existing.descriptionSource = description.isEmpty ? nil : (catalog?.descriptionSource ?? existing.descriptionSource)
            existing.physicalLocation = location.isEmpty ? nil : location
            existing.status = status.rawValue
            existing.rating = rating
            existing.loanedTo = loanedToText.isEmpty ? nil : loanedToText
            existing.loanedDate = loanedDate
            existing.coverImageURL = cover
            existing.updatedAt = Date()
            try? modelContext.save()
            dismiss()
        } else {
            let book = Book(
                title: trimmedTitle,
                authors: authors,
                isbn: catalog?.isbn,
                publicationYear: year,
                genres: genres,
                coverImageURL: cover,
                publisher: publisherText.isEmpty ? nil : publisherText,
                pageCount: pageCount,
                bookDescription: description.isEmpty ? nil : description,
                descriptionSource: description.isEmpty ? nil : (catalog?.descriptionSource ?? nil),
                language: catalog?.language,
                physicalLocation: location.isEmpty ? nil : location,
                status: status.rawValue,
                rating: rating,
                loanedTo: loanedToText.isEmpty ? nil : loanedToText,
                loanedDate: loanedDate
            )
            let key = catalog?.isbn ?? ""
            if findDuplicate(key: key) != nil {
                pendingInsertBook = book
                showDuplicateAlert = true
            } else {
                modelContext.insert(book)
                try? modelContext.save()
                onSaved()
                if dismissOnSave {
                    dismiss()
                }
            }
        }
    }

    private func findDuplicate(key: String) -> Book? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.isbn == trimmed })
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            return nil
        }
    }
}

/// A horizontal row of star buttons for rating.
struct RatingPicker: View {
    @Binding var rating: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    rating = (rating == value) ? nil : value
                } label: {
                    Image(systemName: (rating ?? 0) >= value ? "star.fill" : "star")
                        .foregroundStyle((rating ?? 0) >= value ? .yellow : Color(uiColor: .tertiaryLabel))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
