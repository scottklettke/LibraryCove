import SwiftUI
import SwiftData

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case grid = "grid"
    case list = "list"
    case byLocation = "location"
    case dashboard = "dashboard"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .byLocation: return "mappin.and.ellipse"
        case .dashboard: return "chart.pie"
        }
    }
}

/// How the list view should group books.
enum LibraryGrouping: String, CaseIterable, Identifiable {
    case none = "none"
    case author = "author"
    case genre = "genre"
    case shelf = "shelf"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .author: return "Author"
        case .genre: return "Tags"
        case .shelf: return "Shelf"
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

/// Main library screen: all books with cover grid, list, by-location, and dashboard views.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.title) private var books: [Book]
    /// Members — resolve "Added by" names for search.
    @Query private var users: [User]

    @State private var viewMode: LibraryViewMode = .grid
    @State private var searchText = ""
    @State private var showAdd = false
    @State private var grouping: LibraryGrouping = .none
    @State private var filteredAuthors = Set<String>()
    @State private var filteredTags = Set<String>()
    @State private var showAuthorFilter = false
    @State private var showTagFilter = false
    @State private var sortOrder: LibrarySort = .titleAsc
    @State private var isScrolled = false
    @State private var filteredSheet: FilteredSheet?
    @State private var genreStore = GenreStore()
    @State private var shelfStore = ShelfStore()
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var assignmentTarget: AssignmentTarget?
    @State private var longPressBook: Book?
    @State private var pushedBook: BookRoute?

    private var filteredBooks: [Book] {
        let visible = books.filter { $0.status != BookStatus.donated.rawValue }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched: [Book]
        if query.isEmpty {
            searched = visible
        } else {
            // Resolve owner names once for the whole filtered set.
            let namesByID = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0.displayName) })
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

    private func isSortField(_ field: LibrarySortField) -> Bool {
        sortOrder.field == field
    }

    private func toggleSortField(_ field: LibrarySortField) {
        switch field {
        case .title:
            sortOrder = (sortOrder == .titleAsc) ? .titleDesc : .titleAsc
        case .author:
            sortOrder = (sortOrder == .authorAsc) ? .authorDesc : .authorAsc
        case .dateAdded:
            sortOrder = (sortOrder == .dateNewest) ? .dateOldest : .dateNewest
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
                    Group {
                        Button {
                            showAuthorFilter = true
                        } label: {
                            Label(authorFilterLabel, systemImage: "person")
                        }
                        Button {
                            showTagFilter = true
                        } label: {
                            Label(tagFilterLabel, systemImage: "tag")
                        }
                    }
                    Menu {
                        sortMenuItem(.title)
                        sortMenuItem(.author)
                        sortMenuItem(.dateAdded)
                        Button("Tap a field again to reverse the order") {}
                            .disabled(true)
                            .accessibilityHidden(true)
                    } label: {
                        Label(sortOrder.displayName, systemImage: "arrow.up.arrow.down")
                    }
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
                showAdd = true
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private var groupLabel: String {
        grouping == .none ? "Group" : "Group: \(grouping.displayName)"
    }

    private func sortMenuItem(_ field: LibrarySortField) -> some View {
        Button {
            toggleSortField(field)
        } label: {
            Label(sortFieldLabel(field), systemImage: isSortField(field) ? "checkmark" : "arrow.up.arrow.down")
        }
    }


    private func sortFieldLabel(_ field: LibrarySortField) -> String {
        switch field {
        case .title:
            return isSortField(.title) ? "Title (A–Z)" : "Title (Z–A)"
        case .author:
            return isSortField(.author) ? "Author (A–Z)" : "Author (Z–A)"
        case .dateAdded:
            return isSortField(.dateAdded) ? "Date added (newest)" : "Date added (oldest)"
        }
    }

    /// The main grid/list shows only masters — one representative per ISBN —
    /// so duplicate copies never flood the list. All copies remain reachable
    /// through a master's detail page.
    private var displayBooks: [Book] {
        BookMastering.masters(of: filteredBooks)
    }

    /// Copies stored per normalized ISBN, for the "N copies" badge on masters.
    private var copyCounts: [String: Int] {
        BookMastering.copyCounts(byISBN: visibleBooks)
    }

    private func copyBadge(for book: Book) -> Int {
        guard let normalized = Book.normalizedISBN(book.isbn) else { return 0 }
        return copyCounts[normalized] ?? 1
    }

    private var authorFilterLabel: String {
        filteredAuthors.isEmpty ? "Author" : "Author (\(filteredAuthors.count))"
    }

    private var tagFilterLabel: String {
        filteredTags.isEmpty ? "Tag" : "Tag (\(filteredTags.count))"
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

    private func delete(_ books: [Book]) {
        for book in books {
            CoverImageStore.delete(forBookID: book.id)
            modelContext.delete(book)
        }
        try? modelContext.save()
        if isSelecting { selection.subtract(books.map(\.id)) }
    }

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
        books.filter { $0.status != BookStatus.donated.rawValue }
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
                case .byLocation: byLocationView
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
        .sheet(isPresented: $showAuthorFilter) {
            MultiSelectFilterSheet(title: "Authors", items: allAuthors, selection: filteredAuthors) {
                filteredAuthors = $0
            }
        }
        .sheet(isPresented: $showTagFilter) {
            MultiSelectFilterSheet(title: "Tags", items: allGenres, selection: filteredTags) {
                filteredTags = $0
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
            Button("Delete", role: .destructive) {
                if let book = longPressBook { delete([book]) }
                longPressBook = nil
            }
            Button("Cancel", role: .cancel) { longPressBook = nil }
        } message: {
            Text("Choose an action for this book.")
        }
        .toolbar(isScrolled ? .hidden : .visible, for: .tabBar)
        .onChange(of: viewMode) { isScrolled = false }
        .onChange(of: grouping) { isScrolled = false }
        .sheet(isPresented: $showAdd) {
            AddBookView()
        }
        .navigationDestination(item: $pushedBook) { route in
            BookDetailView(book: route.book)
        }
        .searchable(text: $searchText, prompt: "Search title, author, added by, notes…")
        .overlay {
            if books.isEmpty {
                ContentUnavailableView(
                    "Your library is empty",
                    systemImage: "books.vertical",
                    description: Text("Add your first book from the catalog or scan an ISBN.")
                )
            }
        }
        .overlay(alignment: .center) {
            if books.isEmpty {
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
                                Text(key ?? "Unknown")
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
                NavigationLink {
                    BookDetailView(book: book)
                } label: {
                    BookListRow(book: book, showAddedDate: sortOrder.sortsByDate, copyCount: copyBadge(for: book))
                }
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
                    Section(key ?? "Unknown") {
                        ForEach(grouped[key] ?? []) { book in
                            NavigationLink {
                                BookDetailView(book: book)
                            } label: {
                                BookListRow(book: book, copyCount: copyBadge(for: book))
                            }
                        }
                    }
                }
            })
        }
    }

    private func groupKey(for book: Book) -> String? {
        switch grouping {
        case .author: return book.authors.first
        case .genre: return book.tags.first
        case .shelf: return book.shelves.first
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

    // MARK: - By location

    private var byLocationView: some View {
        let grouped = Dictionary(grouping: filteredBooks, by: \.physicalLocation)
        return List {
            let locations = grouped.keys.sorted {
                ($0 ?? "") < ($1 ?? "")
            }
            ForEach(locations, id: \.self) { location in
                let shelf = grouped[location] ?? []
                Section(location ?? "Unplaced") {
                    if grouping == .none {
                        // Default: books ordered by the active sort (Title A–Z).
                        ForEach(shelf) { book in
                            locationRow(for: book)
                        }
                    } else {
                        // Author/genre subgroups, alphabetical by group name
                        // (books still in title order within each group).
                        let sub = Dictionary(grouping: shelf) { book in
                            groupKey(for: book)
                        }
                        let keys = sub.keys.sorted { ($0 ?? "") < ($1 ?? "") }
                        ForEach(keys, id: \.self) { key in
                            Section {
                                ForEach(sub[key] ?? []) { book in
                                    locationRow(for: book)
                                }
                            } header: {
                                Text(key ?? "Unknown")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func locationRow(for book: Book) -> some View {
        NavigationLink {
            BookDetailView(book: book)
        } label: {
            BookListRow(book: book, showAddedDate: sortOrder.sortsByDate)
        }
    }

    // MARK: - Dashboard

    private var dashboardView: some View {
        let libraryBooks = books.filter { $0.status != BookStatus.donated.rawValue }
        return List {
            Section("Summary") {
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

    var body: some View {
        HStack(spacing: 12) {
            AsyncCoverView(url: CoverImageStore.displayURL(forCover: book.coverImageURL), width: 40, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                if showAddedDate {
                    HStack(spacing: 4) {
                        Text(book.authorsText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("· \(addedDateFormatter.string(from: book.createdAt))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(book.authorsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if copyCount > 1 {
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
