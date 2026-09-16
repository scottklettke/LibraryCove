import SwiftUI
import SwiftData
import PDFKit

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case grid = "grid"
    case list = "list"
    case dashboard = "dashboard"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .dashboard: return "chart.pie"
        }
    }
}

/// How the list view should group books.
enum LibraryGrouping: String, CaseIterable, Identifiable {
    case none = "none"
    case author = "author"
    case genre = "genre"
    case location = "location"
    case series = "series"
    case genres = "genres"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .author: return "Author"
        case .genre: return "Tags"
        case .location: return "Location"
        case .series: return "Series"
        case .genres: return "Genres"
        }
    }
}

/// The sort fields available in the Sort menu.
enum LibrarySortField: String, CaseIterable, Identifiable {
    case title = "title"
    case author = "author"
    case dateAdded = "dateAdded"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: return "Title"
        case .author: return "Author"
        case .dateAdded: return "Date added"
        }
    }
}

/// How the library should order books, including direction. The Sort menu
/// shows one entry per field; selecting a field again toggles its direction.
enum LibrarySort: String, CaseIterable, Identifiable {
    case titleAsc = "titleAsc"
    case titleDesc = "titleDesc"
    case authorAsc = "authorAsc"
    case authorDesc = "authorDesc"
    case dateNewest = "dateNewest"
    case dateOldest = "dateOldest"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .titleAsc: return "Title (A–Z)"
        case .titleDesc: return "Title (Z–A)"
        case .authorAsc: return "Author (A–Z)"
        case .authorDesc: return "Author (Z–A)"
        case .dateNewest: return "Date added (newest first)"
        case .dateOldest: return "Date added (oldest first)"
        }
    }

    var field: LibrarySortField {
        switch self {
        case .titleAsc, .titleDesc: return .title
        case .authorAsc, .authorDesc: return .author
        case .dateNewest, .dateOldest: return .dateAdded
        }
    }

    /// Whether the current sort orders by the date the book was added.
    var sortsByDate: Bool {
        self == .dateNewest || self == .dateOldest
    }
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollOffsetTracker: View {
    var body: some View {
        GeometryReader { proxy in
            let offset = proxy.frame(in: .named("libraryScroll")).minY
            Color.clear
                .preference(key: ScrollOffsetPreferenceKey.self, value: offset)
        }
    }
}

/// Main library screen: all books with cover grid, list, and dashboard views.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    /// The active member — the greeting reads THIS object (the same
    /// instance Settings renames), not a query result that could resolve to
    /// a different row when duplicate active members exist.
    let user: User
    @Query(sort: \Book.title) private var books: [Book]
    /// Observes the active library so switching libraries re-filters the grid.
    @ObservedObject private var libraryScope = LibraryScope.shared
    /// Members — resolve "Added by" names for search.
    @Query private var users: [User]

    @State private var viewMode: LibraryViewMode = .grid
    @State private var searchText = ""
    @State private var showAdd = false
    @State private var grouping: LibraryGrouping = .none
    @State private var filteredAuthors = Set<String>()
    @State private var filteredTags = Set<String>()
    @State private var showFilter = false
    @State private var sortOrder: LibrarySort = .titleAsc
    @State private var isScrolled = false
    /// Bumped whenever LibraryScope posts `librariesChangedNotification` so
    /// the toolbar library menu re-evaluates and picks up Settings-side
    /// creates/renames/deletes (`activeID` alone wouldn't refresh those).
    @State private var registryEpoch = 0
    @State private var filteredSheet: FilteredSheet?
    @State private var genreStore = GenreStore()
    @State private var shelfStore = ShelfStore()
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    /// Books deleted this session whose backing data has detached. SwiftData's
    /// isDeleted flips back to false once save() commits, so this explicit set
    /// is the only reliable "never render this row" signal during the
    /// @Query refresh window after a delete.
    @State private var deletedIDs = Set<String>()
    @State private var assignmentTarget: AssignmentTarget?
    @State private var longPressBook: Book?
    /// Copy chooser for deleting one of several copies of a title.
    @State private var copyPickerBook: Book?
    @State private var pushedBook: BookRoute?
    @State private var isExportingPDF = false
    @State private var pdfURL: URL?
    @State private var showPDFShare = false
    @State private var showExportOptions = false
    @State private var exportOptions = PDFExportOptions()

    private var filteredBooks: [Book] {
        let visible = books.filter {
            !deletedIDs.contains($0.id) && !$0.isDeleted
                && $0.status != BookStatus.donated.rawValue
                && $0.libraryID == libraryScope.activeID
        }
        let searched: [Book]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searched = visible
        } else {
            // Resolve owner names once for the whole filtered set. Duplicate
            // user rows must not be fatal here (search runs on every
            // keystroke) — the first name wins.
            var namesByID: [String: String] = [:]
            for user in users where namesByID[user.id] == nil { namesByID[user.id] = user.displayName }
            let activeName = users.first(where: \.isActive)?.displayName ?? ""
            searched = visible.filter { book in
                let haystack = [
                    book.title,
                    book.authorsText,
                    book.tags.joined(separator: " "),
                    book.physicalLocation ?? "",
                    book.bookDescription ?? "",
                    (book.notes ?? []).map(\.content).joined(separator: " "),
                    book.ownerID.flatMap { namesByID[$0] } ?? activeName
                ].joined(separator: " ").lowercased()
                return haystack.contains(query.lowercased())
            }
        }
        var result = searched
        if !filteredAuthors.isEmpty {
            result = result.filter { book in
                filteredAuthors.contains { wanted in
                    book.authors.contains { $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
                }
            }
        }
        if !filteredTags.isEmpty {
            result = result.filter { book in
                filteredTags.contains { wanted in
                    book.tags.contains { $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
                }
            }
        }
        return result.sorted { lhs, rhs in
            switch sortOrder {
            case .titleAsc:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .titleDesc:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            case .authorAsc:
                return lastName(of: lhs) < lastName(of: rhs)
            case .authorDesc:
                return lastName(of: lhs) > lastName(of: rhs)
            case .dateNewest:
                return lhs.createdAt > rhs.createdAt
            case .dateOldest:
                return lhs.createdAt < rhs.createdAt
            }
        }
    }

    private func lastName(of book: Book) -> String {
        guard let first = book.authors.first else { return "" }
        let parts = first.split(separator: " ")
        return parts.last.map(String.init) ?? first
    }

    private func lastName(of author: String) -> String {
        let parts = author.split(separator: " ")
        return parts.last.map(String.init) ?? author
    }



    /// The direction the current sort runs in (ascending = A–Z / newest first).
    private var sortAscending: Bool {
        sortOrder == .titleAsc || sortOrder == .authorAsc || sortOrder == .dateNewest
    }

    /// Applies an explicit field + direction choice from the Sort menu.
    private func applySort(field: LibrarySortField, ascending: Bool) {
        switch (field, ascending) {
        case (.title, true): sortOrder = .titleAsc
        case (.title, false): sortOrder = .titleDesc
        case (.author, true): sortOrder = .authorAsc
        case (.author, false): sortOrder = .authorDesc
        case (.dateAdded, true): sortOrder = .dateNewest
        case (.dateAdded, false): sortOrder = .dateOldest
        }
    }

    /// The library toolbar, extracted so the body's expressions stay
    /// type-checkable.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if isSelecting {
                // Selection mode replaces the leading controls with a single
                // obvious exit — previously the only way out was the
                // "Done" item hiding inside the overflow "…" menu.
                Button {
                    toggleSelecting()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                }
                .accessibilityIdentifier("cancelSelection")
            } else {
                modePicker
                if viewMode != .dashboard {
                    Menu {
                        Picker("Group by", selection: $grouping) {
                            ForEach(LibraryGrouping.allCases) { group in
                                Text(group.displayName).tag(group)
                            }
                        }
                    } label: {
                        Label(groupLabel, systemImage: "rectangle.3.group")
                    }
                    Button {
                        showFilter = true
                    } label: {
                        Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("filterButton")
                    Menu {
                        Picker("Sort by", selection: Binding(
                            get: { sortOrder.field },
                            set: { applySort(field: $0, ascending: sortAscending) }
                        )) {
                            ForEach(LibrarySortField.allCases) { field in
                                Text(field.displayName).tag(field)
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Picker("Order", selection: Binding(
                            get: { sortAscending },
                            set: { applySort(field: sortOrder.field, ascending: $0) }
                        )) {
                            Text("Ascending").tag(true)
                            Text("Descending").tag(false)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(sortOrder.displayName, systemImage: "arrow.up.arrow.down")
                    }
                    Menu {
                        // Re-evaluates when Settings creates/renames/deletes
                        // a library (activeID wouldn't change in those cases).
                        let _ = registryEpoch
                        let activateLibrary = { (library: LibraryInfo) in
                            LibraryScope.shared.activate(library, context: modelContext)
                            selection = []
                            filteredAuthors = []
                            filteredTags = []
                        }
                        ForEach(LibraryScope.shared.all(context: modelContext)) { library in
                            let name = library.name.isEmpty ? "Untitled Library" : library.name
                            if library.id == libraryScope.activeID {
                                Button {
                                    activateLibrary(library)
                                } label: {
                                    Label(name, systemImage: "checkmark")
                                }
                            } else {
                                Button {
                                    activateLibrary(library)
                                } label: {
                                    Text(name)
                                }
                            }
                        }
                    } label: {
                        Label(libraryScope.activeName(context: modelContext, memberName: user.displayName),
                              systemImage: "chevron.down")
                    }
                    .accessibilityIdentifier("librarySwitcher")
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !displayBooks.isEmpty {
                Button(isSelecting ? "Done" : "Select") {
                    toggleSelecting()
                }
            }
            Button {
                showExportOptions = true
            } label: {
                Label("Export PDF", systemImage: "doc.richtext")
            }
            .disabled(isExportingPDF)
            .accessibilityIdentifier("exportPDF")
            Button {
                showAdd = true
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private var groupLabel: String {
        grouping == .none ? "Group" : "Group: \(grouping.displayName)"
    }

    private var filterLabel: String {
        let count = filteredAuthors.count + filteredTags.count
        return count == 0 ? "Filter" : "Filter (\(count))"
    }


    /// The main grid/list shows only masters — one representative per ISBN —
    /// so duplicate copies never flood the list. All copies remain reachable
    /// through a master's detail page.
    private var displayBooks: [Book] {
        BookMastering.masters(of: filteredBooks).filter { !deletedIDs.contains($0.id) }
    }

    /// Copies stored per normalized ISBN, for the "N copies" badge on masters.
    private var copyCounts: [String: Int] {
        BookMastering.copyCounts(byISBN: visibleBooks)
    }

    private func copyBadge(for book: Book) -> Int {
        guard let normalized = Book.normalizedISBN(book.isbn) else { return 0 }
        return copyCounts[normalized] ?? 1
    }


    // MARK: - Manual tag/shelf assignment + bulk select

    /// A pending assignment: which kind of value (tags or shelves) applied to
    /// which books. Presented as a searchable multi-select sheet.
    private struct AssignmentTarget: Identifiable {
        enum Kind { case tags, shelves }
        let id = UUID()
        let kind: Kind
        let books: [Book]
    }

    /// A pending push to a book's detail page (taps navigate).
    private struct BookRoute: Identifiable, Hashable {
        let id = UUID()
        let book: Book
        static func == (lhs: BookRoute, rhs: BookRoute) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Grid cell that either navigates (tap) with a long-press menu for manual
    /// tagging/assignment, or toggles bulk-selection when selection mode is on.
    private func makeCell(for book: Book) -> some View {
        let cell = BookGridCell(book: book, showAddedDate: sortOrder.sortsByDate, copyCount: copyBadge(for: book))
        if isSelecting {
            let isSelected = selection.contains(book.id)
            return AnyView(
                Button {
                    toggleSelection(book.id)
                } label: {
                    cell
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                                .padding(4)
                                .background(.thinMaterial, in: Circle())
                                .padding(4)
                        }
                }
                .buttonStyle(.plain)
            )
        }
        return AnyView(
            cell
                .contentShape(Rectangle())
                .onTapGesture {
                    pushedBook = BookRoute(book: book)
                }
                .onLongPressGesture(minimumDuration: 0.6) {
                    longPressBook = book
                }
        )
    }

    private func toggleSelecting() {
        isSelecting.toggle()
        if !isSelecting { selection = [] }
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private var selectedBooks: [Book] {
        displayBooks.filter { selection.contains($0.id) }
    }

    private func presentAssignment(_ kind: AssignmentTarget.Kind, _ books: [Book]) {
        assignmentTarget = AssignmentTarget(kind: kind, books: books)
    }

    private func assignmentSheet(_ target: AssignmentTarget) -> some View {
        let known = target.kind == .shelves ? shelfStore.shelves : genreStore.tags
        let initial = Set(target.books.flatMap { book in
            target.kind == .shelves ? book.shelves : book.tags
        })
        return AssignValuesSheet(
            title: target.kind == .shelves ? "Assign to shelf" : "Edit tags",
            valueLabel: target.kind == .shelves ? "shelf" : "tag",
            knownValues: known,
            initialValues: initial,
            onDone: { values in applyAssignment(values, to: target) }
        )
    }

    private func applyAssignment(_ values: Set<String>, to target: AssignmentTarget) {
        let list = values.sorted()
        for book in target.books {
            if target.kind == .shelves {
                book.shelves = list
            } else {
                book.tags = list
            }
        }
        // Register any new custom values so they become suggested later.
        for value in list {
            if target.kind == .shelves {
                _ = shelfStore.add(value)
            } else {
                _ = genreStore.add(value)
            }
        }
        try? modelContext.save()
    }

    /// Identifies which copy of a title a delete target is (location, loan,
    /// or added date), and notes sibling copies that will remain. Used in
    /// delete confirmations so multi-copy titles are unambiguous.
    private func deleteContextMessage(for book: Book?) -> String {
        guard let book else { return "Choose an action for this book." }
        var parts: [String] = []
        if let location = book.physicalLocation, !location.isEmpty {
            parts.append("located in \(location)")
        }
        if let loanedTo = book.loanedTo, !loanedTo.isEmpty {
            parts.append("loaned to \(loanedTo)")
        }
        let all = (try? modelContext.fetch(LibraryScope.shared.activeBooksDescriptor(context: modelContext))) ?? []
        let copyCount = BookMastering.otherCopies(of: book, in: all).count + 1
        let identity: String
        if parts.isEmpty {
            let date = book.acquiredDate ?? book.createdAt
            identity = "the copy added \(addedShortFormatter.string(from: date))"
        } else {
            identity = "the copy \(parts.joined(separator: ", "))"
        }
        if copyCount > 1 {
            return "This is \(identity). You have \(copyCount) copies of this title — deleting removes only this one."
        }
        return "This is \(identity). Choose an action for this book."
    }
    /// Number of OTHER copies of the same title (0 = the only copy).
    private func copyCountExcludingSelf(_ book: Book) -> Int {
        let all = (try? modelContext.fetch(LibraryScope.shared.activeBooksDescriptor(context: modelContext))) ?? []
        return BookMastering.otherCopies(of: book, in: all).count
    }

    private var addedShortFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private func delete(_ books: [Book]) {
        // Read the id before delete(): after save() the backing data is
        // detached and even .id can fault.
        let ids = books.map(\.id)
        deletedIDs.formUnion(ids)
        for book in books {
            CoverImageStore.delete(forBookID: book.id)
            modelContext.delete(book)
        }
        // One save for the whole batch — the deleted models detach here, so
        // nothing may touch their attributes afterwards.
        try? modelContext.save()
        if isSelecting { selection.subtract(ids) }
    }
    /// Exports "what you see": the selection while selecting, otherwise the
    /// current filtered/sorted masters. SwiftData models are snapshotted on the
    /// main actor; the heavy render runs off-main and hands back a PDF file.
    private func exportPDF() {
        let exportBooks = isSelecting ? selectedBooks : displayBooks
        guard !exportBooks.isEmpty else { return }
        isExportingPDF = true
        var ownerNames: [String: String] = [:]
        for user in users where ownerNames[user.id] == nil { ownerNames[user.id] = user.displayName }
        let title = "Library Catalog"
        let filtersNote = Self.exportFiltersNote(
            isSelecting: isSelecting,
            searchText: searchText,
            filteredAuthors: filteredAuthors,
            filteredTags: filteredTags
        )
        let options = exportOptions
        let brandImage = UIImage(named: "BrandMark")
        Task {
            let entries = await LibraryPDFExport.makeEntries(
                from: exportBooks,
                ownerNames: ownerNames
            )
            let data = await Task.detached(priority: .userInitiated) {
                LibraryPDFExport.render(entries, title: title, options: options, brandImage: brandImage, filtersNote: filtersNote)
            }.value
            isExportingPDF = false
            guard let data else {
                showExportOptions = false
                return
            }
            let name = LibraryDataService.exportFileName(
                kind: "Catalog",
                libraryName: libraryScope.activeName(context: modelContext, memberName: user.displayName),
                memberName: user.displayName,
                ext: "pdf"
            )
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url)
            pdfURL = url
            showExportOptions = false
            showPDFShare = true
            if isSelecting { toggleSelecting() }
        }
    }

    /// One-line description of the filters scoping this export, printed on
    /// the PDF cover so readers know what the catalog represents. Selection
    /// mode, search text, and author/tag filters are all surfaced; nil means
    /// the export covers the whole library with no scoping.
    static func exportFiltersNote(
        isSelecting: Bool,
        searchText: String,
        filteredAuthors: Set<String>,
        filteredTags: Set<String>
    ) -> String? {
        var parts: [String] = []
        if isSelecting { parts.append("selected books") }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { parts.append("search “\(query)”") }
        switch filteredAuthors.count {
        case 1: parts.append("author \(filteredAuthors.first!)")
        case 2...3: parts.append("authors \(filteredAuthors.sorted().joined(separator: ", "))")
        case 4...: parts.append("\(filteredAuthors.count) authors")
        default: break
        }
        switch filteredTags.count {
        case 1: parts.append("tag \(filteredTags.first!)")
        case 2...3: parts.append("tags \(filteredTags.sorted().joined(separator: ", "))")
        case 4...: parts.append("\(filteredTags.count) tags")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Per-export choices: layout, cover size, and which fields the PDF
    /// includes. "Create PDF" kicks off the render and opens the preview.
    private var pdfOptionsSheet: some View {
        NavigationStack {
            Form {
                Section("Layout") {
                    Picker("Layout", selection: $exportOptions.layout) {
                        ForEach(PDFExportOptions.Layout.allCases) { layout in
                            Text(layout.displayName).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    if exportOptions.layout == .cards {
                        Picker("Cover size", selection: $exportOptions.coverSize) {
                            ForEach(PDFExportOptions.CoverSize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Include") {
                    Toggle("Reading stats page", isOn: $exportOptions.includeStats)
                    Toggle("Description", isOn: $exportOptions.includeDescription)
                    Toggle("Series", isOn: $exportOptions.includeSeries)
                    Toggle("Location", isOn: $exportOptions.includeLocation)
                    Toggle("Rating", isOn: $exportOptions.includeRating)
                    Toggle("Shelves", isOn: $exportOptions.includeShelves)
                    Toggle("Tags", isOn: $exportOptions.includeTags)
                    Toggle("ISBN", isOn: $exportOptions.includeISBN)
                }
            }
            .navigationTitle("Export PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showExportOptions = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create PDF") {
                        exportPDF()
                    }
                    .disabled(isExportingPDF)
                    .accessibilityIdentifier("pdfCreate")
                }
            }
        }
        .overlay {
            // Visible feedback while the PDF renders off-main; without it the
            // options sheet just closes and the app looks idle.
            if isExportingPDF {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Creating PDF…")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .accessibilityIdentifier("pdfProgress")
            }
        }
    }

    /// Full in-app preview of the rendered PDF, with a share button.
    private var pdfPreviewSheet: some View {
        NavigationStack {
            Group {
                if let pdfURL {
                    PDFKitView(url: pdfURL)
                } else {
                    ContentUnavailableView("No PDF", systemImage: "doc.richtext")
                }
            }
            .navigationTitle("PDF Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let pdfURL {
                        ShareLink(item: pdfURL) {
                            Label("Save or share PDF", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("pdfShare")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPDFShare = false }
                }
            }
        }
    }

    /// PDFKit-backed preview; a bare `PDFView` filling available space.
    private struct PDFKitView: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> PDFViewController {
            let controller = PDFViewController()
            controller.view.backgroundColor = .secondarySystemBackground
            return controller
        }

        func updateUIViewController(_ controller: PDFViewController, context: Context) {
            controller.loadIfNeeded(url: url)
        }
    }

    /// Holds one `PDFView` and (re)loads the document on demand, so SwiftUI
    /// re-renders never stack documents.
    private final class PDFViewController: UIViewController {
        let pdfView = PDFView()
        private var loadedURL: URL?

        override func viewDidLoad() {
            super.viewDidLoad()
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            pdfView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(pdfView)
            NSLayoutConstraint.activate([
                pdfView.topAnchor.constraint(equalTo: view.topAnchor),
                pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        func loadIfNeeded(url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            pdfView.document = PDFDocument(url: url)
        }
    }


    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()


    private var bulkActionBar: some View {
        HStack(spacing: 12) {
            Text(selection.isEmpty ? "Nothing selected" : "\(selection.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Tag") {
                presentAssignment(.tags, selectedBooks)
            }
            .disabled(selection.isEmpty)
            Button("Shelf") {
                presentAssignment(.shelves, selectedBooks)
            }
            .disabled(selection.isEmpty)
            Button("Delete", role: .destructive) {
                delete(selectedBooks)
                isSelecting = false
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var visibleBooks: [Book] {
        books.filter {
            !deletedIDs.contains($0.id) && !$0.isDeleted
                && $0.status != BookStatus.donated.rawValue
                && $0.libraryID == libraryScope.activeID
        }
    }

    private var allAuthors: [String] {
        Set(visibleBooks.flatMap(\.authors)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var allGenres: [String] {
        Set(visibleBooks.flatMap(\.tags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            if hasActiveFilters {
                activeFiltersBar
            }
            Group {
                switch viewMode {
                case .grid: gridView
                case .list: listView
                case .dashboard: dashboardView
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                bulkActionBar
            }
        }
        .toolbar {
            toolbarContent
        }
    }

    var body: some View {
        libraryContent
            .sheet(item: $filteredSheet) { sheet in
                FilteredBooksSheet(sheet: sheet)
            }
        .sheet(item: $assignmentTarget) { target in
            assignmentSheet(target)
        }
        .sheet(isPresented: $showFilter) {
            MultiSelectFilterSheet(searchTextPlaceholder: "Search authors or tags", sections: [
                .init(title: "Authors", items: allAuthors, selection: filteredAuthors,
                      onChange: { filteredAuthors = $0 }),
                .init(title: "Tags", items: allGenres, selection: filteredTags,
                      onChange: { filteredTags = $0 })
            ])
        }
        .sheet(item: $copyPickerBook, onDismiss: { longPressBook = nil }) { book in
            CopyDeletePicker(
                title: book.title.isEmpty ? "Delete a copy" : book.title,
                copies: [book] + BookMastering.otherCopies(of: book, in: books)
            ) { chosen in
                delete([chosen])
            }
        }
        .confirmationDialog(
            longPressBook?.title ?? "Book",
            isPresented: Binding(
                get: { longPressBook != nil },
                set: { if !$0 { longPressBook = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Assign to shelf…") {
                if let book = longPressBook { presentAssignment(.shelves, [book]) }
                longPressBook = nil
            }
            Button("Edit tags…") {
                if let book = longPressBook { presentAssignment(.tags, [book]) }
                longPressBook = nil
            }
            Button("Delete copy…", role: .destructive) {
                if let book = longPressBook {
                    if copyCountExcludingSelf(book) >= 1 {
                        // Multi-copy: present the picker; longPressBook stays
                        // (it marks "this one") and clears when the sheet closes.
                        copyPickerBook = book
                    } else {
                        delete([book])
                        longPressBook = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { longPressBook = nil }
        } message: {
            Text(deleteContextMessage(for: longPressBook))
        }
        .toolbar(isScrolled ? .hidden : .visible, for: .tabBar)
        .onChange(of: viewMode) { isScrolled = false }
        .onChange(of: grouping) { isScrolled = false }
        .sheet(isPresented: $showAdd) {
            AddBookView()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryScope.librariesChangedNotification)) { _ in
            registryEpoch += 1
        }
        .sheet(isPresented: $showExportOptions) {
            pdfOptionsSheet
        }
        .sheet(isPresented: $showPDFShare) {
            pdfPreviewSheet
        }
        .navigationDestination(item: $pushedBook) { route in
            BookDetailView(book: route.book)
        }
        .searchable(text: $searchText, prompt: "Search title, author, added by, notes…")
        .overlay {
            // The empty-state overlay applies to the book-browsing modes
            // only — the Dashboard renders stats (zeros when empty) and
            // must not have text stacked on top of its rows.
            if visibleBooks.isEmpty && viewMode != .dashboard {
                ContentUnavailableView {
                    VStack(spacing: 12) {
                        Image("BrandMark")
                            .resizable()
                            .aspectRatio(1, contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityIdentifier("brandMarkEmpty")
                            .accessibilityLabel("LibraryCove")
                        Text(greetingText)
                            .font(.title2.bold())
                        Text("Your library is empty")
                            .font(.body)
                    }
                } description: {
                    Text("Add your first book from the catalog or scan an ISBN.")
                }
            }
        }
        .overlay(alignment: .center) {
            if visibleBooks.isEmpty && viewMode != .dashboard {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .background(Circle().fill(.blue))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                }
                .accessibilityLabel("Add a book")
                // Below the empty-state text so it never overlaps.
                .offset(y: 190)
            }
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $viewMode) {
            ForEach(LibraryViewMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("modePicker")
    }

    /// "Hi, Scott J" — the active member's full display name (the `user`
    /// instance passed from RootView — the same object Settings renames).
    /// Falls back to a plain greeting when no name is resolvable.
    private var greetingText: String {
        let name = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            // The "Your library is empty" line renders right below; avoid
            // printing it twice when no name is resolvable.
            return "Hi"
        }
        return "Hi, \(name)"
    }


    // MARK: - Grid

    private var gridView: some View {
        if grouping == .none {
            return AnyView(
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                        ForEach(displayBooks) { book in
                            makeCell(for: book)
                        }
                    }
                    .padding()
                    .background(ScrollOffsetTracker())
                }
                .coordinateSpace(name: "libraryScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                    isScrolled = offset < -30
                }
            )
        } else {
            let grouped = Dictionary(grouping: displayBooks) { book in
                groupKey(for: book)
            }
            let keys = grouped.keys.sorted { lhs, rhs in
                if grouping == .author, let lhs, let rhs {
                    return lastName(of: lhs) < lastName(of: rhs)
                }
                return (lhs ?? "") < (rhs ?? "")
            }
            return AnyView(
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(keys, id: \.self) { key in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                                    ForEach(grouped[key] ?? []) { book in
                                        makeCell(for: book)
                                    }
                                }
                                .padding()
                            } header: {
                                Text(grouping == .location && key == nil ? "Unplaced" : key ?? "Unknown")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                    .background(Color(uiColor: .systemGroupedBackground))
                            }
                        }
                    }
                    .background(ScrollOffsetTracker())
                }
                .coordinateSpace(name: "libraryScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                    isScrolled = offset < -30
                }
            )
        }
    }

    // MARK: - List

    private var listView: some View {
        if grouping == .none {
            return AnyView(List(displayBooks) { book in
                listRow(for: book, showAddedDate: sortOrder.sortsByDate)
            })
        } else {
            let grouped = Dictionary(grouping: displayBooks) { book in
                groupKey(for: book)
            }
            let keys = grouped.keys.sorted {
                ($0 ?? "") < ($1 ?? "")
            }
            return AnyView(List {
                ForEach(keys, id: \.self) { key in
                    Section(grouping == .location && key == nil ? "Unplaced" : key ?? "Unknown") {
                        ForEach(grouped[key] ?? []) { book in
                            listRow(for: book, showAddedDate: false)
                        }
                    }
                }
            })
        }
    }

    /// One list row: a NavigationLink to the book while browsing, or — in
    /// selection mode — a row whose trailing status icon toggles selection
    /// while taps anywhere else still push the book's details.
    @ViewBuilder
    private func listRow(for book: Book, showAddedDate: Bool) -> some View {
        if isSelecting {
            BookListRow(
                book: book,
                showAddedDate: showAddedDate,
                copyCount: copyBadge(for: book),
                isSelecting: true,
                isSelected: selection.contains(book.id),
                onToggleSelection: { toggleSelection(book.id) },
                onOpenDetails: { pushedBook = BookRoute(book: book) }
            )
        } else {
            NavigationLink {
                BookDetailView(book: book)
            } label: {
                BookListRow(book: book, showAddedDate: showAddedDate, copyCount: copyBadge(for: book))
            }
        }
    }

    private func groupKey(for book: Book) -> String? {
        // A just-deleted book can still appear in a stale query snapshot;
        // reading its attributes traps ("detached ... without resolving
        // attribute faults"). Skip it instead.
        switch grouping {
        case .author: return book.authors.first
        case .genre: return book.tags.first
        case .location: return book.physicalLocation
        case .series: return book.series
        case .genres: return book.genre.flatMap { BookGenre(rawValue: $0)?.displayName ?? $0 }
        case .none: return nil
        }
    }

    private var hasActiveFilters: Bool {
        grouping != .none || !filteredAuthors.isEmpty || !filteredTags.isEmpty
    }

    private var activeFiltersBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if grouping != .none {
                    chip("Grouped by \(grouping.displayName)", systemImage: "rectangle.3.group") {
                        grouping = .none
                    }
                }
                ForEach(filteredAuthors.sorted(), id: \.self) { author in
                    chip("Author: \(author)", systemImage: "person") {
                        filteredAuthors.remove(author)
                    }
                }
                ForEach(filteredTags.sorted(), id: \.self) { tag in
                    chip("Tag: \(tag)", systemImage: "tag") {
                        filteredTags.remove(tag)
                    }
                }
                Spacer()
                Button("Clear all filters") {
                    grouping = .none
                    filteredAuthors = []
                    filteredTags = []
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func chip(_ text: String, systemImage: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Label(text, systemImage: systemImage)
                .font(.caption)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
    }

    // MARK: - Dashboard

    private var dashboardView: some View {
        let libraryBooks = books.filter {
            !deletedIDs.contains($0.id) && $0.status != BookStatus.donated.rawValue
                && $0.libraryID == libraryScope.activeID
        }
        return List {
            Section {
                LabeledContent("Total books", value: "\(libraryBooks.count)")
                LabeledContent("Reading", value: "\(count(status: .reading))")
                LabeledContent("To read", value: "\(count(status: .toRead))")
                LabeledContent("Completed", value: "\(count(status: .completed))")
                Button {
                    filteredSheet = FilteredSheet(title: "Loaned out", books: libraryBooks.filter(\.isLoaned))
                } label: {
                    HStack {
                        Text("Loaned out")
                        Spacer()
                        Text("\(libraryBooks.filter(\.isLoaned).count)")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    filteredSheet = FilteredSheet(title: "Donated", books: libraryBooks.filter { $0.status == BookStatus.donated.rawValue })
                } label: {
                    HStack {
                        Text("Donated")
                        Spacer()
                        Text("\(count(status: .donated))")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Image("BrandMark")
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("brandMarkHeader")
                        .accessibilityLabel("LibraryCove")
                    Text("Summary")
                }
            }
            Section("By location") {
                let counts = Dictionary(grouping: libraryBooks, by: \.physicalLocation)
                let locations = counts.keys.sorted {
                    ($0 ?? "") < ($1 ?? "")
                }
                ForEach(locations, id: \.self) { location in
                    LabeledContent(location ?? "Unplaced", value: "\(counts[location]?.count ?? 0)")
                }
            }
            Section("Recently added") {
                let recent = libraryBooks.sorted { $0.createdAt > $1.createdAt }.prefix(10)
                ForEach(Array(recent)) { book in
                    NavigationLink {
                        BookDetailView(book: book)
                    } label: {
                        BookListRow(book: book)
                    }
                }
            }
        }
    }

    private func count(status: BookStatus) -> Int {
        books.filter { $0.status == status.rawValue }.count
    }
}

/// Grid cell: cover + short title (plus the added date when sorting by it,
/// mirroring the list view).
struct BookGridCell: View {
    let book: Book
    var showAddedDate = false
    var copyCount = 0

    var body: some View {
        if book.isDeleted {
            // A deleted book can linger in a stale query snapshot during a
            // re-render; reading its attributes would trap.
            Color.clear.frame(width: 92, height: 134)
        } else {
            cellContent
        }
    }

    private var cellContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncCoverView(url: CoverImageStore.displayURL(forCover: book.coverImageURL), width: 92, height: 134)
                .overlay(alignment: .topLeading) {
                    if book.isLoaned {
                        LoanBadge()
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if copyCount > 1 {
                        Text("×\(copyCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(3)
                    }
                }
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: 92, alignment: .leading)
            if showAddedDate {
                Text(addedDateFormatter.string(from: book.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 92, alignment: .leading)
            }
        }
    }
}

/// Small badge showing a book is loaned out.
struct LoanBadge: View {
    var body: some View {
        Image(systemName: "person.fill")
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(4)
            .background(.blue)
            .clipShape(Circle())
            .shadow(radius: 1)
            .padding(3)
    }
}

/// List row: cover thumbnail + title/author/status.
struct BookListRow: View {
    let book: Book
    var showAddedDate = false
    var copyCount = 0
    /// Selection mode: the trailing status icon becomes the selection toggle.
    var isSelecting = false
    var isSelected = false
    var onToggleSelection: (() -> Void)? = nil
    /// Selection mode: tapping the cover/title area opens the book's details.
    /// Applied only to the leading stack so the icon Button sits outside the
    /// gesture (List tap precedence between a Button and a parent gesture is
    /// unreliable across row recycling).
    var onOpenDetails: (() -> Void)? = nil

    var body: some View {
        if book.isDeleted {
            Color.clear.frame(height: 58)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            leadingContent
            Spacer()
            if isSelecting, let onToggleSelection {
                Button {
                    onToggleSelection()
                } label: {
                    Image(systemName: isSelected ? book.statusEnum.filledSystemImage : book.statusEnum.systemImage)
                        .foregroundStyle(isSelected ? Color.accentColor : Color(uiColor: .secondaryLabel))
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("listSelectToggle")
                .accessibilityLabel(isSelected ? "Deselect \(book.title)" : "Select \(book.title)")
            } else if copyCount > 1 {
                Text("\(copyCount) copies")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: book.statusEnum.systemImage)
                    .foregroundStyle(.secondary)
            }
            if book.isLoaned {
                Image(systemName: "person.fill")
                    .foregroundStyle(.blue)
            }
        }
    }

    /// Cover + title/author. In selection mode this stack carries the
    /// details tap; the trailing icon Button stays a gesture-free sibling.
    private var leadingContent: some View {
        let stack = HStack(spacing: 12) {
            AsyncCoverView(url: CoverImageStore.displayURL(forCover: book.coverImageURL), width: 40, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                if showAddedDate {
                    HStack(spacing: 4) {
                        Text(book.authorsText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\u{b7} \(addedDateFormatter.string(from: book.createdAt))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(book.authorsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if isSelecting, let onOpenDetails {
            return AnyView(
                stack
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenDetails() }
            )
        }
        return AnyView(stack)
    }
}

extension BookStatus {
    var systemImage: String {
        switch self {
        case .reading: return "book.open"
        case .toRead: return "bookmark"
        case .completed: return "checkmark.circle"
        case .donated: return "heart"
        }
    }

    /// Filled variant shown when a list row is selected in bulk-selection
    /// mode (the status icon doubles as the selection toggle).
    var filledSystemImage: String {
        switch self {
        case .reading: return "book.fill"
        case .toRead: return "bookmark.fill"
        case .completed: return "checkmark.circle.fill"
        case .donated: return "heart.fill"
        }
    }
}

/// A filtered book list presented from the dashboard.
struct FilteredSheet: Identifiable {
    let id = UUID()
    let title: String
    let books: [Book]
}

/// Sheet listing a filtered set of books (e.g. loaned out or donated).
struct FilteredBooksSheet: View {
    let sheet: FilteredSheet

    var body: some View {
        NavigationStack {
            List(sheet.books) { book in
                NavigationLink {
                    BookDetailView(book: book)
                } label: {
                    BookListRow(book: book)
                }
            }
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Formats the date a book was added for display in list rows.
private let addedDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
}()
