import SwiftUI
import SwiftData

/// Encodes a captured cover photo into the stored `data:` URL form.
///
/// Camera photos hold far more pixels than any cover ever renders on screen
/// (the largest cover is ~100×140pt ≈ 300px wide at 3x), so they are downscaled
/// to `maxPixelDimension` before JPEG compression. 640px keeps every on-screen
/// cover sharp while the embedded base64 stays small — roughly a quarter of the
/// old 900pt cap (which actually stored ~2700px on a 3x screen).
enum CoverImageData {
    /// Longest edge in stored pixels. 480px covers the largest render
    /// (92×134pt @3x = 276×402px) with headroom and keeps every photo cover
    /// small. Imported catalog covers are typically ~500px wide already, so
    /// this makes photos match them.
    static let maxPixelDimension: CGFloat = 480
    static let compressionQuality: CGFloat = 0.8

    /// Resizes `image` so its longest edge is at most `maxPixelDimension`
    /// pixels, keeping aspect ratio. Smaller images are returned unchanged.
    /// A scale-1 renderer is used so the pixel size is exact (not × screen
    /// scale), making the stored JPEG predictable.
    static func resize(_ image: UIImage, maxPixelDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxPixelDimension else { return image }
        let scale = maxPixelDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Returns `image` as a `data:image/jpeg;base64,` URL, resized to
    /// `maxPixelDimension` if needed. `nil` if JPEG encoding fails.
    static func encode(_ image: UIImage) -> String? {
        let resized = resize(image, maxPixelDimension: maxPixelDimension)
        guard let jpeg = resized.jpegData(compressionQuality: compressionQuality) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    /// Decodes the payload of a `data:image/...;base64,` URL back to bytes.
    static func data(fromDataURL urlString: String) -> Data? {
        guard urlString.hasPrefix("data:"),
              let comma = urlString.firstIndex(of: ",") else { return nil }
        let base64 = urlString[urlString.index(after: comma)...]
        return Data(base64Encoded: String(base64))
    }

    /// Re-encodes image bytes down to `maxPixelDimension`. Used when storing
    /// legacy covers (or photos) that predate the small-size pipeline so they
    /// get shrunk too. `nil` if the bytes aren't an image or encoding fails.
    static func normalize(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return resize(image, maxPixelDimension: maxPixelDimension)
            .jpegData(compressionQuality: compressionQuality)
    }
}

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
    /// The active member — books are attributed to them as "added by".
    @Query private var users: [User]

    let catalog: CatalogBook?
    var existing: Book?
    var onSaved: () -> Void = {}
    var onDeleted: () -> Void = {}
    var dismissOnSave: Bool = true
    /// Hides the form's own toolbar trash. Used inside the swipeable import
    /// pager, where the pager owns a single trash for the whole flow instead —
    /// several forms are live during a page transition and would each push a
    /// trash into the same nav bar, flashing duplicates while swiping.
    var showsToolbarDelete = true

    @State private var title = ""
    @State private var authorsText = ""
    @State private var yearText = ""
    @State private var tagsText = ""
    @State private var publisherText = ""
    @State private var pageCountText = ""
    @State private var description = ""
    @State private var locationText = ""
    @State private var status: BookStatus = .toRead
    @State private var kind: BookKind = .notSet
    @State private var rating: Int?
    @State private var coverURLs: [String] = []
    @State private var selectedCover: String?
    @State private var selectedPhotoCover: String?
    @State private var showCamera = false
    @State private var photoToCrop: UIImage?
    @State private var showCropper = false
    @State private var cropSource: UIImage?
    @State private var locationStore = LocationStore()
    @State private var genreStore = GenreStore()
    @State private var genreQuery = ""
    @State private var loanedToText = ""
    @State private var loanedDate: Date?
    @State private var descriptionSource: DescriptionSource = .openlibrary
    @State private var isFetchingDescription = false
    @State private var fetchError: String?
    @State private var showDuplicateAlert = false
    @State private var showDeleteConfirmation = false
    @State private var pendingInsertBook: Book?
    /// The already-in-library book a new add collides with, so the alert can
    /// offer deleting the duplicate.
    @State private var pendingDuplicate: Book?
    // Validation feedback: Title is required to save.
    @State private var titleMissingAttempted = false
    @FocusState private var titleFieldFocused: Bool
    /// Bumped to scroll the title field into view on a failed save.
    @State private var scrollTrigger = 0

    init(catalog: CatalogBook? = nil, existing: Book? = nil, onSaved: @escaping () -> Void = {}, onDeleted: @escaping () -> Void = {}, dismissOnSave: Bool = true, showsToolbarDelete: Bool = true) {
        self.catalog = catalog
        self.existing = existing
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        self.dismissOnSave = dismissOnSave
        self.showsToolbarDelete = showsToolbarDelete
        _status = State(initialValue: existing?.statusEnum ?? .toRead)
        _kind = State(initialValue: existing.flatMap { BookKind(rawValue: $0.kind) } ?? .notSet)
        _rating = State(initialValue: existing?.rating)

        if let catalog {
            _title = State(initialValue: catalog.title)
            _authorsText = State(initialValue: catalog.authors.joined(separator: ", "))
            _yearText = State(initialValue: catalog.publicationYear.map { String($0) } ?? "")
            _tagsText = State(initialValue: "")
            _publisherText = State(initialValue: catalog.publisher ?? "")
            _pageCountText = State(initialValue: catalog.pageCount.map { String($0) } ?? "")
            _description = State(initialValue: catalog.description ?? "")
            _coverURLs = State(initialValue: catalog.coverURLs)
            _selectedCover = State(initialValue: catalog.primaryCoverURL)
        } else if let existing {
            _title = State(initialValue: existing.title)
            _authorsText = State(initialValue: existing.authors.joined(separator: ", "))
            _yearText = State(initialValue: existing.publicationYear.map { String($0) } ?? "")
            _tagsText = State(initialValue: existing.tags.joined(separator: ", "))
            _publisherText = State(initialValue: existing.publisher ?? "")
            _pageCountText = State(initialValue: existing.pageCount.map { String($0) } ?? "")
            _description = State(initialValue: existing.bookDescription ?? "")
            _locationText = State(initialValue: existing.physicalLocation ?? "")
            _coverURLs = State(initialValue: existing.coverImageURL.map { [$0] } ?? [])
            _selectedCover = State(initialValue: existing.coverImageURL)
        }
    }

    /// Whether the edit form differs from the existing book (drives the top Save button).
    private var hasChanges: Bool {
        guard let book = existing else { return false }
        return title != book.title
            || authorsText != book.authors.joined(separator: ", ")
            || yearText != (book.publicationYear.map { String($0) } ?? "")
            || tagsText != book.tags.joined(separator: ", ")
            || publisherText != (book.publisher ?? "")
            || pageCountText != (book.pageCount.map { String($0) } ?? "")
            || description != (book.bookDescription ?? "")
            || locationText != (book.physicalLocation ?? "")
            || status != book.statusEnum
            || kind != (BookKind(rawValue: book.kind) ?? .notSet)
            || rating != book.rating
            || loanedToText != (book.loanedTo ?? "")
            || selectedCover != book.coverImageURL
    }


    var body: some View {
        ScrollViewReader { proxy in
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
            .onChange(of: scrollTrigger) { _, _ in
                withAnimation { proxy.scrollTo("bookFormTitle", anchor: .top) }
            }
        }
        .task {
            // New-add from a catalog: enrich the form with catalog details.
            if catalog != nil {
                await fetchDescription()
            } else if let existing,
                      (existing.bookDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                // Editing a book with no description: auto-fill from the catalog.
                await fetchDescription()
            }
            // Editing a book that already has a description (incl. an AI-revised
            // or AI-summarized one) never auto-fetches — doing so would clobber
            // the stored text with the original catalog description.
        }
        .sheet(isPresented: $showCamera) {
            // Camera first; once a photo is captured the sheet's content swaps
            // to the crop view in place (so no sheet-on-sheet animation races).
            if let image = photoToCrop {
                PhotoCropView(sourceImage: image) { cropped in
                    applyCropped(cropped)
                    photoToCrop = nil
                    showCamera = false
                }
                .onDisappear { photoToCrop = nil }
            } else {
                CameraPicker { image in
                    photoToCrop = image
                    selectedCover = nil
                }
            }
        }
        .sheet(isPresented: $showCropper) {
            // Re-crop of an already-stored cover, presented on its own so it
            // can never collide with the camera sheet.
            if let source = cropSource {
                PhotoCropView(sourceImage: source) { cropped in
                    applyCropped(cropped)
                    cropSource = nil
                    showCropper = false
                }
                .onDisappear { cropSource = nil }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if existing != nil {
                    Button("Cancel") { dismiss() }
                }
            }
            if existing != nil && hasChanges {
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { save() }
                }
            }
            if (existing != nil || catalog != nil) && showsToolbarDelete {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
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
            Button("Delete duplicate", role: .destructive) {
                if let duplicate = pendingDuplicate {
                    CoverImageStore.delete(forBookID: duplicate.id)
                    modelContext.delete(duplicate)
                }
                if let pending = pendingInsertBook {
                    modelContext.insert(pending)
                }
                try? modelContext.save()
                pendingInsertBook = nil
                pendingDuplicate = nil
                onSaved()
                if dismissOnSave {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingInsertBook = nil
                pendingDuplicate = nil
            }
        } message: {
            Text("You already have this book. Add another copy, delete the existing one and add this instead, or cancel.")
        }
        .alert("Delete this book?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteBook()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var coverSection: some View {
    Section {
        if let photo = selectedPhotoCover, let url = URL(string: photo) {
            AsyncCoverView(url: url, width: 100, height: 140)
        } else if let url = CoverImageStore.displayURL(forCover: selectedCover) {
            AsyncCoverView(url: url, width: 100, height: 140)
        }

        // Crop an already-stored local cover (photo or previously downloaded)
        // into just the book cover. Hidden for remote-only URLs with no local
        // pixels to work with.
        if let image = currentCoverImage() {
            Button {
                cropSource = image
                showCropper = true
            } label: {
                Label("Crop cover", systemImage: "crop")
                    .font(.callout)
            }
        }

        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(coverURLs, id: \.self) { url in
                    Button {
                        selectedCover = url
                        selectedPhotoCover = nil
                    } label: {
                        AsyncCoverView(url: CoverImageStore.displayURL(forCover: url), width: 56, height: 80)
                            .overlay(alignment: .bottomTrailing) {
                                if selectedCover == url {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.white, .blue)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showCamera = true
                } label: {
                    VStack {
                        Image(systemName: "camera")
                            .font(.title2)
                        Text("Photo")
                            .font(.caption2)
                    }
                    .frame(width: 56, height: 80)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    } header: {
        Text("Cover")
    }
}

    private var detailsSection: some View {
        Section {
            TextField("Title *", text: $title)
                .focused($titleFieldFocused)
                .id("bookFormTitle")
            if titleMissingAttempted && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Title is required.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
                    ForEach(genreStore.tags, id: \.self) { genre in
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
            Picker("Type", selection: $kind) {
                ForEach(BookKind.allCases) { k in
                    Text(k.displayName).tag(k)
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

        guard let found = result else {
            fetchError = "No details found for this book."
            return
        }

        if let newDescription = found.description { description = newDescription }
        if !found.tags.isEmpty { tagsText = found.tags.joined(separator: ", ") }
        if let publisher = found.publisher { publisherText = publisher }
        if let pages = found.pageCount { pageCountText = String(pages) }
        if let year = found.publicationYear { yearText = String(year) }

        // Merge fetched covers with the book's current cover instead of
        // replacing it, so editing never wipes the user's selection.
        let keptCover = existing?.coverImageURL
        let merged = (keptCover.map { [$0] } ?? []) + found.coverURLs.filter { $0 != keptCover }
        if !merged.isEmpty { coverURLs = merged }
    }

    private var catalogISBN: String? {
        if let isbn = catalog?.isbn { return isbn }
        return existing?.isbn
    }

    private var selectedGenres: [String] {
        tagsText.split(separator: ",").map(String.init).map {
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
        tagsText = list.joined(separator: ", ")
    }

    private func removeGenre(_ genre: String) {
        let list = selectedGenres.filter { $0.caseInsensitiveCompare(genre) != .orderedSame }
        tagsText = list.joined(separator: ", ")
    }

    private var addedDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    /// Deletes an already-saved book, or discards an unsaved import
    /// (when `existing` is nil the book was never inserted).
    private func deleteBook() {
        if let book = existing {
            CoverImageStore.delete(forBookID: book.id)
            modelContext.delete(book)
            try? modelContext.save()
        }
        if dismissOnSave {
            dismiss()
        }
        onDeleted()
    }

    private var deleteMessage: String {
        if existing != nil {
            return "This book will be removed from your library."
        }
        return "This book won't be added to your library."
    }


    private func applyCropped(_ cropped: UIImage) {
        if let cover = CoverImageData.encode(cropped) {
            selectedPhotoCover = cover
            selectedCover = nil
        }
    }

    /// The cover currently showing, as local pixels (for cropping). Returns a
    /// non-nil image only for `data:` photo covers — i.e. photos the user
    /// took; online and imported covers aren't offered for cropping.
    private func currentCoverImage() -> UIImage? {
        let cover = selectedPhotoCover ?? selectedCover ?? existing?.coverImageURL
        guard let cover, cover.hasPrefix("data:") else { return nil }
        return CoverImageData.data(fromDataURL: cover).flatMap(UIImage.init(data:))
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            // Title is required; tell the user and scroll to the field instead
            // of silently doing nothing.
            titleMissingAttempted = true
            titleFieldFocused = true
            scrollTrigger += 1
            return
        }
        let authors = authorsText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let tags = tagsText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let year = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        let pageCount = Int(pageCountText.trimmingCharacters(in: .whitespacesAndNewlines))
        let location = locationText == "__new__" ? "" : locationText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty {
            locationStore.add(location)
        }

        // New books get their id up front so a photo cover can be written to
        // the file system under the same id the database will use.
        let newID = existing == nil ? UUID().uuidString : nil
        let cover = selectedPhotoCover ?? selectedCover ?? existing?.coverImageURL
        // Materialize user-taken cover photos as small files on disk (backing
        // export bundling and offline restore). The database keeps the `data:`
        // URL form — it's what marks this cover as a user-taken photo (only
        // those offer cropping). Re-normalize legacy/large photos to the same
        // target size as freshly captured ones.
        if let dataCover = cover, dataCover.hasPrefix("data:"),
           let storeID = existing?.id ?? newID,
           let bytes = CoverImageData.data(fromDataURL: dataCover)
                .flatMap(CoverImageData.normalize)
                ?? CoverImageData.data(fromDataURL: dataCover) {
            CoverImageStore.save(bytes, forBookID: storeID)
        }

        if let existing {
            existing.title = trimmedTitle
            existing.authors = authors
            existing.publicationYear = year
            existing.tags = tags
            existing.publisher = publisherText.isEmpty ? nil : publisherText
            existing.pageCount = pageCount
            existing.bookDescription = description.isEmpty ? nil : description
            existing.descriptionSource = description.isEmpty ? nil : (catalog?.descriptionSource ?? existing.descriptionSource)
            existing.physicalLocation = location.isEmpty ? nil : location
            existing.status = status.rawValue
            existing.kind = kind.rawValue
            existing.rating = rating
            existing.loanedTo = loanedToText.isEmpty ? nil : loanedToText
            existing.loanedDate = loanedDate
            existing.coverImageURL = cover
            existing.updatedAt = Date()
            try? modelContext.save()
            dismiss()
        } else {
            let book = Book(id: newID!,
                title: trimmedTitle,
                authors: authors,
                isbn: Book.normalizedISBN(catalog?.isbn),
                publicationYear: year,
                tags: tags,
                kind: kind.rawValue,
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
                loanedDate: loanedDate,
                ownerID: users.first(where: \.isActive)?.id
            )
            let key = catalog?.isbn ?? ""
            if let duplicate = findDuplicate(key: key) {
                pendingInsertBook = book
                pendingDuplicate = duplicate
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
        // Compare by normalized ISBN (digits only) so dashed/spaced spellings
        // of the same ISBN still match. SQL predicates can't normalize, so
        // match in Swift over the (small) library.
        guard let normalized = Book.normalizedISBN(key) else { return nil }
        guard let books = try? modelContext.fetch(FetchDescriptor<Book>()) else { return nil }
        return books.first { Book.normalizedISBN($0.isbn) == normalized }
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

/// Camera capture wrapper for taking a photo on the spot.
private struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            // No dismiss here: BookFormView swaps this sheet's content to the
            // crop view, so dismissing would tear the sheet down mid-transition.
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
