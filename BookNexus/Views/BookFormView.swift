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

    init(catalog: CatalogBook? = nil, existing: Book? = nil) {
        self.catalog = catalog
        self.existing = existing
        _status = State(initialValue: existing?.statusEnum ?? .toRead)
        _rating = State(initialValue: existing?.rating)

        if let catalog {
            _title = State(initialValue: catalog.title)
            _authorsText = State(initialValue: catalog.authors.joined(separator: ", "))
            _yearText = State(initialValue: catalog.publicationYear.map { String($0) } ?? "")
            _genresText = State(initialValue: catalog.genres.joined(separator: ", "))
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
            saveSection
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if existing != nil {
                    Button("Cancel") { dismiss() }
                }
            }
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
            HStack {
                TextField("Year", text: $yearText)
                    .keyboardType(.numberPad)
                TextField("Page count", text: $pageCountText)
                    .keyboardType(.numberPad)
            }
            TextField("Publisher", text: $publisherText)
                .textInputAutocapitalization(.words)
            TextField("Genres (comma separated)", text: $genresText)
                .textInputAutocapitalization(.words)
            if let isbn = catalog?.isbn ?? existing?.isbn {
                LabeledContent("ISBN", value: isbn)
            }
        } header: {
            Text("Details")
        } footer: {
            Text("Fields marked * are required.")
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
            locationPicker
            TextEditor(text: $description)
                .frame(minHeight: 80)
        } header: {
            Text("Status & notes")
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
            existing.physicalLocation = location.isEmpty ? nil : location
            existing.status = status.rawValue
            existing.rating = rating
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
                language: catalog?.language,
                physicalLocation: location.isEmpty ? nil : location,
                status: status.rawValue,
                rating: rating
            )
            modelContext.insert(book)
            try? modelContext.save()
            dismiss()
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
