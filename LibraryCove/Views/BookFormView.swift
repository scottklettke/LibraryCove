import SwiftUI
import SwiftData
import SafariServices
import WebKit

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
    /// Called after a Book row is inserted and saved (including the
    /// duplicate-alert "add another copy" branch) with the saved title, so the
    /// presenter can confirm to the user. Deliberately NOT set for scan/import
    /// flows: those immediately dismiss or tear down the presenting screen,
    /// and presenting a confirmation alert during that dismissal crashes
    /// (NSInternalInconsistencyException in
    /// _alertControllerContainedInViewController).
    var onAdded: (String) -> Void = { _ in }
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
    @State private var languageText = ""
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
    @State private var descriptionSource: DescriptionSource = .wikipedia
    /// Where the description currently in the editor came from — the raw
    /// source string persisted with the book on save ("openlibrary", or a
    /// comma-joined union when identical texts merged across sources).
    @State private var activeDescriptionSource: String?
    @State private var isFetchingDescription = false
    /// In-flight flag for the "Retrieve additional covers" button.
    @State private var isFetchingCovers = false
    @State private var fetchError: String?
    /// Message for the "Retrieve additional covers" button (shown in the
    /// cover section, not the description section).
    @State private var coversFetchMessage: String?
    /// Set by deleteBook() before the model detaches. While true, the form
    /// body must not read `existing`'s attributes (they trap after save()
    /// detaches the backing data).
    @State private var bookDeleted = false
    /// Set when the user deletes the description while an auto-fetch is in
    /// flight, so the fetch's late result doesn't clobber the cleared field.
    @State private var clearedFetchedDescription = false
    @State private var showDescriptionPicker = false
    /// Description candidates for the "Choose from sources" sheet, loaded
    /// when the sheet opens.
    @State private var descriptionCandidates: [(text: String, sources: [String?])] = []
    @State private var isLoadingCandidates = false
    /// Web search for manually copying a description (opens Safari).
    @State private var webSearchURL: URL?
    @State private var showDuplicateAlert = false
    @State private var showDeleteConfirmation = false
    /// Sheet for choosing which copy of a multi-copy title to delete.
    @State private var showCopyPicker = false
    @State private var pendingInsertBook: Book?
    /// The already-in-library book a new add collides with, so the alert can
    /// offer deleting the duplicate.
    @State private var pendingDuplicate: Book?
    // Validation feedback: Title is required to save.
    @State private var titleMissingAttempted = false
    @FocusState private var titleFieldFocused: Bool
    /// Bumped to scroll the title field into view on a failed save.
    @State private var scrollTrigger = 0

    init(catalog: CatalogBook? = nil, existing: Book? = nil, onSaved: @escaping () -> Void = {}, onAdded: @escaping (String) -> Void = { _ in }, onDeleted: @escaping () -> Void = {}, dismissOnSave: Bool = true, showsToolbarDelete: Bool = true) {
        self.catalog = catalog
        self.existing = existing
        self.onSaved = onSaved
        self.onAdded = onAdded
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
            _languageText = State(initialValue: catalog.language ?? "")
            _pageCountText = State(initialValue: catalog.pageCount.map { String($0) } ?? "")
            _description = State(initialValue: catalog.description ?? "")
            _activeDescriptionSource = State(initialValue: catalog.descriptionSource)
            _coverURLs = State(initialValue: catalog.coverURLs)
            // Default to the catalog's first cover so Add-to-library always
            // saves one even if the user never taps a thumbnail.
            _selectedCover = State(initialValue: catalog.primaryCoverURL)
        } else if let existing {
            _title = State(initialValue: existing.title)
            _authorsText = State(initialValue: existing.authors.joined(separator: ", "))
            _yearText = State(initialValue: existing.publicationYear.map { String($0) } ?? "")
            _tagsText = State(initialValue: existing.tags.joined(separator: ", "))
            _languageText = State(initialValue: existing.language ?? "")
            _pageCountText = State(initialValue: existing.pageCount.map { String($0) } ?? "")
            _description = State(initialValue: existing.bookDescription ?? "")
            _activeDescriptionSource = State(initialValue: existing.descriptionSource)
            _locationText = State(initialValue: existing.physicalLocation ?? "")
            _selectedCover = State(initialValue: existing.coverImageURL)
            // Show the stored cover (if any) in the picker strip so the user
            // sees what's set; more can be fetched with "Retrieve additional
            // covers".
            _coverURLs = State(initialValue: existing.coverImageURL.map { [$0] } ?? [])
        }
    }

    /// Whether the edit form differs from the existing book (drives the top Save button).
    private var hasChanges: Bool {
        guard let book = existing, !book.isDeleted else { return false }
        return title != book.title
            || authorsText != book.authors.joined(separator: ", ")
            || yearText != (book.publicationYear.map { String($0) } ?? "")
            || tagsText != book.tags.joined(separator: ", ")
            || pageCountText != (book.pageCount.map { String($0) } ?? "")
            || languageText != (book.language ?? "")
            || description != (book.bookDescription ?? "")
            || activeDescriptionSource != book.descriptionSource
            || locationText != (book.physicalLocation ?? "")
            || status != book.statusEnum
            || kind != (BookKind(rawValue: book.kind) ?? .notSet)
            || rating != book.rating
            || loanedToText != (book.loanedTo ?? "")
            || selectedCover != book.coverImageURL
    }

    var body: some View {
        if bookDeleted {
            // Deleted: every read of `existing`'s attributes would trap
            // (backing data detached by save()). Render nothing during the
            // dismissal animation.
            Color.clear
        } else {
            formContent
        }
    }

    private var formContent: some View {
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
            // A fully-manual entry (blank catalog stub) has nothing to fetch
            // — skip the network entirely.
            if catalog != nil, !(catalog?.title.isEmpty ?? true) || catalog?.isbn?.isEmpty == false {
                await fetchDescription()
            } else if let existing,
                      (existing.bookDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                // Editing a book with no description: auto-fill from the catalog.
                await fetchDescription()
            }
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
        .sheet(isPresented: $showDescriptionPicker) {
            DescriptionPickerSheet(
                isbn: catalogISBN,
                title: title,
                authors: authorsList,
                current: description,
                currentSource: activeDescriptionSource,
                olKey: catalog?.olWorkKey ?? existing?.olKey,
                candidates: $descriptionCandidates,
                isLoading: $isLoadingCandidates,
                onPick: { picked, sources in
                    description = picked
                    let picked = sources.compactMap { $0 }.joined(separator: ",")
                    activeDescriptionSource = picked.isEmpty ? nil : picked
                    clearedFetchedDescription = isFetchingDescription
                    showDescriptionPicker = false
                },
                onWebSearch: {
                    webSearchURL = WebSearchEngine.bookDescriptionURL(title: title,
                                                                      authors: authorsList)
                    showDescriptionPicker = false
                })
        }
        .sheet(item: $webSearchURL) { url in
            WebSearchBrowser(
                url: url,
                onImportSelection: { text, pageURL in
                    // Keep the existing text and append, or start fresh
                    // when empty. Attribution goes to the page the text was
                    // actually copied from (e.g. "en.wikipedia.org"), not
                    // the search engine the flow started on; when the page
                    // URL is unavailable the search engine host is the best
                    // known origin.
                    if description.isEmpty {
                        description = text
                    } else {
                        description += "\n\n" + text
                    }
                    activeDescriptionSource = pageURL?.host ?? url.host
                    clearedFetchedDescription = isFetchingDescription
                    webSearchURL = nil
                },
                onClose: { webSearchURL = nil })
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
                        // Multi-copy titles: let the user pick which copy
                        // (by added date) instead of a blind confirm.
                        if let book = existing, copyCount(of: book) > 1 {
                            showCopyPicker = true
                        } else {
                            showDeleteConfirmation = true
                        }
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
                    pending.libraryID = LibraryScope.shared.activeID(context: modelContext)
                    try? modelContext.save()
                    pendingInsertBook = nil
                    onAdded(pending.title)
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
                    pending.libraryID = LibraryScope.shared.activeID(context: modelContext)
                    try? modelContext.save()
                    pendingInsertBook = nil
                    onAdded(pending.title)
                    onSaved()
                }
                pendingDuplicate = nil
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
        .sheet(isPresented: $showCopyPicker) {
            CopyDeletePicker(
                title: "Delete a copy",
                copies: allCopiesOfExisting,
                currentBookID: existing?.id
            ) { chosen in
                // Compare by OBJECT IDENTITY, not id: duplicate-id rows
                // (from older merge imports) would otherwise route a sibling
                // pick to deleteBook() and remove the wrong copy.
                if chosen === existing {
                    deleteBook()
                } else {
                    deleteArbitraryCopy(chosen)
                }
            }
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

        Button {
            Task { await retrieveAdditionalCovers() }
        } label: {
            HStack {
                Label(isFetchingCovers ? "Searching…" : "Retrieve additional covers",
                      systemImage: isFetchingCovers ? "hourglass" : "photo.on.rectangle.angled")
                    .font(.callout)
                if isFetchingCovers {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isFetchingCovers || trimmedTitleEmpty)
        if let coversFetchMessage {
            Text(coversFetchMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if trimmedTitleEmpty {
            Text("Add a title to search for covers.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    .contentShape(Rectangle())
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
            TextField("Language", text: $languageText)
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
                    showDescriptionPicker = true
                } label: {
                    Label("Fetch description", systemImage: "text.justify.left")
                }
                .disabled(isFetchingDescription)
                if !description.isEmpty {
                    Button(role: .destructive) {
                        // An auto-fetch that's still in flight must not
                        // resurrect the text after the user deletes it.
                        description = ""
                        activeDescriptionSource = nil
                        clearedFetchedDescription = true
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
            if let source = activeDescriptionSource {
                Text("Source: \(DescriptionSource.label(for: source))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Description")
        } footer: {
            Text("A short summary of the book. \"Fetch description\" lists every description found online — your current text, Open Library, Wikipedia, and Google Books — so you can pick one, or search the web to paste your own.")
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

    /// Wall-clock cap for the form's fetch chain (record + enrichment +
    /// covers + description fallbacks). Each request already has a 12s
    /// timeout; this bounds the WHOLE chain so the "Fetching description…"
    /// row can't hang forever on a flaky network.
    static let fetchDeadlineSeconds: TimeInterval = 45

    private func fetchDescription() async {
        isFetchingDescription = true
        fetchError = nil
        defer { isFetchingDescription = false }

        let service = OpenLibraryService()
        let isbn = catalogISBN
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = authorsText.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        // Copy the view state the lookup needs so the @Sendable closure
        // captures plain values instead of the (non-Sendable) view.
        let preferred = descriptionSource

        // Catalog metadata (tags/publisher/year/pages/covers) + a first-pass
        // description from the ISBN record (Wikipedia-preferred) or a title
        // search — capped so a stalled chain surfaces an error instead of
        // an endless spinner.
        let outcome = await withDeadline(seconds: Self.fetchDeadlineSeconds) {
            () -> CatalogBook?? in
            if let isbn {
                return try? await service.lookup(isbn: isbn, preferred: preferred)
            } else if !trimmedTitle.isEmpty {
                let results = (try? await service.search(query: trimmedTitle, preferred: preferred)) ?? []
                return results.first
            } else {
                return nil
            }
        }
        if outcome.timedOut {
            fetchError = "The catalog is taking too long to answer — check your connection and tap again, or edit the fields by hand."
            return
        }
        let result = outcome.value ?? nil

        // Description: use the record's text; when the ISBN came up empty, an
        // extra title-based lookup (Wikipedia by default) finds one for books
        // whose ISBN "doesn't come up with anything."
        var desc = result?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        var descSource = result?.descriptionSource
        if (desc == nil || desc!.isEmpty) && !trimmedTitle.isEmpty {
            let (text, source) = await service.descriptionByTitle(
                title: trimmedTitle, authors: authors, preferred: descriptionSource,
                olKey: result?.olWorkKey)
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                desc = text
                descSource = source
            }
        }
        if let desc, !desc.isEmpty {
            // The user deleted the description while this fetch was running —
            // respect the clear instead of resurrecting the fetched text.
            guard !clearedFetchedDescription else { return }
            description = desc
            activeDescriptionSource = descSource
        }

        guard let found = result else {
            if desc == nil || desc!.isEmpty {
                fetchError = "No details found for this book."
            }
            return
        }

        // The user deleted the description while this fetch ran — they're
        // actively editing, so don't clobber ANY of their form edits
        // (tags/publisher/pages/year/covers) with catalog data mid-flight.
        if clearedFetchedDescription { return }

        if !found.tags.isEmpty { tagsText = found.tags.joined(separator: ", ") }
        // Merge fetched covers with what's already in the strip instead of
        // replacing it: the user may have already tapped a thumbnail from the
        // catalog list while this fetch was in flight, and the fetch must not
        // (a) drop that candidate or (b) disturb their selection. The chosen
        // cover goes first so the selection stays visible.
        var merged: [String] = []
        if let selectedCover { merged.append(selectedCover) }
        if let kept = existing?.coverImageURL, !merged.contains(kept) { merged.append(kept) }
        var seen = Set(merged)
        for url in found.coverURLs + coverURLs where seen.insert(url).inserted {
            merged.append(url)
        }
        if merged != coverURLs {
            coverURLs = merged
        }

    }

    private var trimmedTitleEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "Retrieve additional covers": looks up cover candidates on demand —
    /// by ISBN when the form has one, else by title+author search — and
    /// merges anything new into the picker strip. Never disturbs the current
    /// selection; also keeps existing strip entries.
    private func retrieveAdditionalCovers() async {
        guard !trimmedTitleEmpty else { return }
        isFetchingCovers = true
        coversFetchMessage = nil
        defer { isFetchingCovers = false }
        let service = OpenLibraryService()
        let isbn = catalogISBN
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await withDeadline(seconds: Self.fetchDeadlineSeconds) {
            () -> CatalogBook?? in
            if let isbn {
                return try? await service.lookup(isbn: isbn, preferred: .openlibrary)
            } else {
                let results = (try? await service.search(query: trimmedTitle, preferred: .openlibrary)) ?? []
                return results.first
            }
        }
        guard !outcome.timedOut, let found = outcome.value ?? nil else {
            coversFetchMessage = "No additional covers found — try again or use the Photo option."
            return
        }
        var merged: [String] = coverURLs
        var seen = Set(merged)
        for url in found.coverURLs where seen.insert(url).inserted {
            merged.append(url)
        }
        if merged.count == coverURLs.count {
            coversFetchMessage = "No additional covers found — try again or use the Photo option."
        }
        coverURLs = merged
    }

    private var authorsList: [String] {
        authorsText.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
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
        // Flag FIRST: during the dismissal animation this view re-renders,
        // and by the time save() commits the book's backing data has
        // detached — any later read of existing's attributes (e.g. the cover
        // section) would trap. bookDeleted forces attribute-free rendering.
        bookDeleted = true
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

    /// Every copy of the edited title (the book itself + its siblings).
    private var allCopiesOfExisting: [Book] {
        guard let book = existing else { return [] }
        let all = (try? modelContext.fetch(LibraryScope.shared.activeBooksDescriptor(context: modelContext))) ?? []
        return [book] + BookMastering.otherCopies(of: book, in: all)
    }

    /// Deletes a copy OTHER than the one being edited: the form stays open
    /// on `existing`. If the picked copy is the edited one, callers route to
    /// `deleteBook()` instead.
    private func deleteArbitraryCopy(_ copy: Book) {
        let id = copy.id
        CoverImageStore.delete(forBookID: id)
        modelContext.delete(copy)
        try? modelContext.save()
        // LibraryView guards stale-query rendering with deletedIDs; this
        // delete happened outside that view, so tell it.
        NotificationCenter.default.post(
            name: .bookDeletedExternally, object: nil, userInfo: ["id": id])
    }
    private var deleteMessage: String {
        if existing != nil {
            var parts: [String] = []
            if let location = existing?.physicalLocation, !location.isEmpty {
                parts.append("located in \(location)")
            }
            if let loanedTo = existing?.loanedTo, !loanedTo.isEmpty {
                parts.append("loaned to \(loanedTo)")
            }
            let copyNote: String
            if let book = existing, copyCount(of: book) > 1 {
                copyNote = " You have \(copyCount(of: book)) copies of this title — only this copy is removed."
            } else {
                copyNote = ""
            }
            if parts.isEmpty {
                return "This copy\(existing?.acquiredDate != nil ? " (added \(addedDateText))" : "") will be removed from your library.\(copyNote)"
            }
            return "This copy (\(parts.joined(separator: ", "))) will be removed from your library.\(copyNote)"
        }
        return "This book won't be added to your library."
    }

    /// Copies of the same title (normalized ISBN, else title match).
    private func copyCount(of book: Book) -> Int {
        let all = (try? modelContext.fetch(LibraryScope.shared.activeBooksDescriptor(context: modelContext))) ?? []
        return BookMastering.otherCopies(of: book, in: all).count + 1
    }

    private var addedDateText: String {
        guard let date = existing?.acquiredDate ?? existing?.createdAt else { return "" }
        return addedDateFormatter.string(from: date)
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
            existing.publisher = publisherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : publisherText.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.pageCount = pageCount
            existing.language = languageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : languageText.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.bookDescription = description.isEmpty ? nil : description
            existing.descriptionSource = description.isEmpty ? nil : (activeDescriptionSource ?? existing.descriptionSource)
            existing.physicalLocation = location.isEmpty ? nil : location
            existing.status = status.rawValue
            existing.kind = kind.rawValue
            existing.rating = rating
            existing.loanedTo = loanedToText.isEmpty ? nil : loanedToText
            existing.loanedDate = loanedDate
            existing.coverImageURL = cover
            // Backfill the work key from a fresh lookup; never clear a stored one.
            if let workKey = catalog?.olWorkKey { existing.olKey = workKey }
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
                descriptionSource: description.isEmpty ? nil : (activeDescriptionSource ?? catalog?.descriptionSource),
                olKey: catalog?.olWorkKey,
                language: languageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : languageText.trimmingCharacters(in: .whitespacesAndNewlines),
                physicalLocation: location.isEmpty ? nil : location,
                status: status.rawValue,
                rating: rating,
                loanedTo: loanedToText.isEmpty ? nil : loanedToText,
                loanedDate: loanedDate,
                ownerID: users.first(where: \.isActive)?.id,
                createdAt: Date(),
                updatedAt: Date()
            )
            let key = catalog?.isbn ?? ""
            if let duplicate = findDuplicate(key: key) {
                pendingInsertBook = book
                pendingDuplicate = duplicate
                showDuplicateAlert = true
            } else {
                modelContext.insert(book)
                book.libraryID = LibraryScope.shared.activeID(context: modelContext)
                try? modelContext.save()
                onAdded(trimmedTitle)
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
        guard let books = try? modelContext.fetch(LibraryScope.shared.activeBooksDescriptor(context: modelContext)) else { return nil }
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

/// Presents a URL in an in-app WebKit browser sheet. Unlike the old
/// SFSafariViewController sheet, a WKWebView can read the page's current text
/// selection, which is what powers "import the highlighted description".
/// The Close button tears the browser down itself by firing `onClose`, which
/// the SwiftUI side binds to `webSearchURL = nil`.
struct WebSearchBrowser: UIViewControllerRepresentable {
    let url: URL
    var onImportSelection: (String, URL?) -> Void
    var onClose: () -> Void = {}

    func makeUIViewController(context: Context) -> UINavigationController {
        // The app's own persistent WKWebsiteDataStore: a Kagi (or any other)
        // login done inside this browser survives restarts — iOS sandboxes
        // prevent reading Safari's cookies, so an in-app session is the only
        // durable one we can offer.
        let webView = WKWebView(frame: .zero, configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            return configuration
        }())
        webView.load(URLRequest(url: url))
        let coordinator = context.coordinator

        let importButton = UIButton(type: .system)
        importButton.setImage(UIImage(systemName: "text.badge.plus"), for: .normal)
        importButton.tintColor = .systemBlue
        importButton.accessibilityLabel = "Import selected text"
        // Hidden until the page actually has a selection.
        importButton.alpha = 0
        importButton.addAction(UIAction { [weak webView, weak importButton] _ in
            guard let webView else { return }
            webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
                guard let text = result as? String else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                coordinator.onImportSelection(trimmed, webView.url)
                importButton?.alpha = 0
            }
        }, for: .touchUpInside)

        let bar = UIToolbar()
        let flexible = UIBarButtonItem(systemItem: .flexibleSpace)
        let importItem = UIBarButtonItem(customView: importButton)
        // Hand-off to the user's real Safari session: iOS sandboxes prevent
        // this in-app browser from reading Safari's cookies, so a site that
        // needs the Safari login (e.g. Kagi) can be opened there instead.
        // Importing is impossible from Safari, so this leaves the sheet open.
        let safariItem = UIBarButtonItem(primaryAction: UIAction { [weak webView] _ in
            guard let url = webView?.url ?? webView?.backForwardList.currentItem?.url else { return }
            UIApplication.shared.open(url)
        })
        safariItem.image = UIImage(systemName: "safari")
        let closeItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { _ in
                coordinator.close()
            })
        bar.items = [closeItem, flexible, safariItem, importItem]

        let container = UIViewController()
        container.view.addSubview(bar)
        container.view.addSubview(webView)
        bar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])

        // The selection appears/clears as the user drags handles, so poll
        // rather than rely on WKWebView delegate callbacks (none fire for
        // selection changes).
        let poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak webView, weak importButton] _ in
            webView?.evaluateJavaScript("String(window.getSelection())") { result, _ in
                let has = (result as? String)?.isEmpty == false
                importButton?.alpha = has ? 1 : 0
                importButton?.isUserInteractionEnabled = has
            }
        }

        let nav = UINavigationController(rootViewController: container)
        nav.toolbar.isHidden = true
        coordinator.install(webView: webView, pollTimer: poll)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    /// SwiftUI's teardown hook (swipe-dismiss included): stops the 0.5s
    /// selection poll so it never outlives the browser. Runs on the main
    /// actor, so it may touch the coordinator's isolated state.
    static func dismantleUIViewController(_ uiViewController: UINavigationController,
                                          coordinator: Coordinator) {
        coordinator.dismiss()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onImportSelection: onImportSelection, onClose: onClose)
    }
    /// Owns the browser's WebView + poll timer. `close()` tears everything
    /// down (Close button); `dismiss()` is the swipe-dismiss path that
    /// `dismantleUIViewController` calls on the main actor.
    @MainActor
    final class Coordinator {
        private var webView: WKWebView?
        private var pollTimer: Timer?
        let onImportSelection: (String, URL?) -> Void
        private let onClose: () -> Void

        init(onImportSelection: @escaping (String, URL?) -> Void,
             onClose: @escaping () -> Void) {
            self.onImportSelection = onImportSelection
            self.onClose = onClose
        }

        func install(webView: WKWebView, pollTimer: Timer) {
            self.webView = webView
            self.pollTimer = pollTimer
        }

        /// Close button: stop polling, then hand dismissal back to SwiftUI
        /// by clearing the `webSearchURL` binding.
        func close() {
            dismiss()
            onClose()
        }

        func dismiss() {
            pollTimer?.invalidate()
            pollTimer = nil
            webView?.stopLoading()
            webView = nil
        }
    }
}

/// A URL wrapped so it can drive `.sheet(item:)`.
extension URL: Identifiable {
    public var id: String { absoluteString }
}

/// "Choose from sources": every description found for the book, one row per
/// source, plus a web-search escape hatch for copying a description by hand.
private struct DescriptionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isbn: String?
    let title: String
    let authors: [String]
    let current: String
    /// Provenance of `current` — a catalog rawValue or a website hostname
    /// from a web import. Threads into the candidates service so the
    /// "current text" row keeps its source label in future fetches.
    let currentSource: String?
    /// Stored Open Library work key (from the catalog result or the existing
    /// book) so the OL candidate resolves via /works/{key}.json directly.
    let olKey: String?
    @Binding var candidates: [(text: String, sources: [String?])]
    @Binding var isLoading: Bool
    let onPick: (String, [String?]) -> Void
    let onWebSearch: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Searching sources…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    List {
                        Section {
                            Button {
                                onWebSearch()
                            } label: {
                                Label("Search the web for this book",
                                      systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        } footer: {
                            Text("No descriptions found in Open Library, Wikipedia, or Google Books (its keyless access is often rate-limited). Try the web search — you can highlight text on the page and import it as the description.")
                        }
                    }
                } else {
                    List {
                        Section {
                            Button {
                                onWebSearch()
                            } label: {
                                Label("Search the web for this book",
                                      systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)

                            // A source that answered empty simply contributes
                            // no row; surface why so the list's silence is
                            // legible (Google Books' keyless endpoint is
                            // frequently rate-limited).
                            let present = Set(candidates.compactMap { row in
                                row.sources.compactMap { $0 }
                            }.joined())
                            if !present.contains("googlebooks") {
                                Text("Google Books returned no description — its keyless access is often rate-limited, so it may be temporarily unavailable.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section {
                            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                                Button {
                                    onPick(candidate.text, candidate.sources)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(candidate.sources.compactMap { $0 }.isEmpty
                                                 ? "Current text"
                                                 : DescriptionSource.label(for: candidate.sources.compactMap { $0 }.joined(separator: ",")))
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.secondary)
                                            if candidate.text == current.trimmingCharacters(in: .whitespacesAndNewlines) {
                                                Text("in use")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tint)
                                            }
                                        }
                                        Text(candidate.text)
                                            .font(.footnote)
                                            .foregroundStyle(.primary)
                                            .lineLimit(6)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                            }
                        } header: {
                            Text("Found online")
                        }
                    }
                }
            }
            .navigationTitle("Descriptions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            if candidates.isEmpty && !isLoading {
                await loadIfNeeded()
            }
        }
    }

    private func loadIfNeeded() async {
        // Copy state into locals: the deadline closure is @Sendable and the
        // view itself is not.
        let service = OpenLibraryService()
        let isbn = self.isbn, title = self.title, authors = self.authors
        let current = self.current, currentSource = self.currentSource
        isLoading = true
        defer { isLoading = false }
        // Cap the whole multi-source sweep: on a flaky network one stalled
        // source used to leave "Searching sources…" spinning forever. On
        // timeout the sheet shows its empty state (with the web-search
        // escape hatch) instead of hanging.
        let outcome = await withDeadline(seconds: BookFormView.fetchDeadlineSeconds) {
            await service.descriptionCandidates(
                isbn: isbn, title: title, authors: authors, current: current,
                currentSource: currentSource, olKey: self.olKey)
        }
        candidates = outcome.value ?? []
    }
}
