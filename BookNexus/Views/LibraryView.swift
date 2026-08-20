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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .author: return "Author"
        case .genre: return "Genre"
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
    @State private var filterAuthor: String?
    @State private var filterGenre: String?
    @State private var sortOrder: LibrarySort = .titleAsc
    @State private var isScrolled = false
    @State private var filteredSheet: FilteredSheet?
    @State private var showGenreCleanup = false
    @State private var showShelfCategories = false
    /// The active canonical shelf plan for "Group by genre". Only set while it
    /// matches the library's current tag set (fingerprint-validated); a stale
    /// or missing plan makes genre grouping fall back to raw tags.
    @State private var shelfPlan: ShelfCategoryPlan?

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
                    book.genres.joined(separator: " "),
                    book.physicalLocation ?? "",
                    book.bookDescription ?? "",
                    book.summary ?? "",
                    (book.notes ?? []).map(\.content).joined(separator: " "),
                    book.ownerID.flatMap { namesByID[$0] } ?? activeName
                ].joined(separator: " ").lowercased()
                return haystack.contains(query.lowercased())
            }
        }
        var result = searched
        if let filterAuthor {
            result = result.filter { book in
                book.authors.contains { $0.localizedCaseInsensitiveCompare(filterAuthor) == .orderedSame }
            }
        }
        if let filterGenre {
            result = result.filter { book in
                book.genres.contains { $0.localizedCaseInsensitiveCompare(filterGenre) == .orderedSame }
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

    /// Canonical shelf sections for "Group by genre", derived from the active
    /// plan. Multi-membership: a book appears under every category its tags map
    /// to, and unmapped books land in a trailing "Other" shelf. Nil when there
    /// is no valid plan — callers fall back to raw-tag grouping.
    private var genreSections: [(category: String, books: [Book])]? {
        guard grouping == .genre, let plan = shelfPlan,
              ShelfCategorizer.isValid(plan, forTags: ShelfCategorizer.allGenres(from: visibleBooks)) else { return nil }
        return ShelfCategorizer.shelfSections(books: filteredBooks, plan: plan)
    }

    /// Loads a valid stored plan, or generates (and caches) a fresh one when
    /// the library's tag set has changed. Model failures degrade gracefully to
    /// raw-tag grouping instead of blocking the library.
    private func refreshShelfPlanIfNeeded() async {
        guard grouping == .genre else { return }
        let tags = ShelfCategorizer.allGenres(from: visibleBooks)
        guard !tags.isEmpty else {
            shelfPlan = nil
            return
        }
        if let stored = ShelfCategorizer.storedPlan(),
           ShelfCategorizer.isValid(stored, forTags: tags) {
            shelfPlan = stored
            return
        }
        if let plan = try? await ShelfCategorizer.generatePlan(books: visibleBooks),
           !plan.mappings.isEmpty {
            shelfPlan = plan
            ShelfCategorizer.store(plan)
        } else {
            shelfPlan = nil
        }
    }

    private var visibleBooks: [Book] {
        books.filter { $0.status != BookStatus.donated.rawValue }
    }

    private var allAuthors: [String] {
        Set(visibleBooks.flatMap(\.authors)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var allGenres: [String] {
        Set(visibleBooks.flatMap(\.genres)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasActiveFilters {
                activeFiltersBar
            }
            // AI genre maintenance. Deliberately in the content area, not the
            // toolbar: on iPhone any extra toolbar item (trailing or leading)
            // is folded into the hidden "More" overflow, which is the opposite
            // of discoverable.
            if !visibleBooks.isEmpty && viewMode != .dashboard {
                HStack {
                    Spacer()
                    aiToolsMenu
                }
                .padding(.horizontal)
                .padding(.top, 6)
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
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                modePicker
                if viewMode != .dashboard {
                    Menu {
                        Picker("Group by", selection: $grouping) {
                            ForEach(LibraryGrouping.allCases) { group in
                                Text(group.displayName).tag(group)
                            }
                        }
                    } label: {
                        Label(grouping == .none ? "Group" : "Group: \(grouping.displayName)", systemImage: "rectangle.3.group")
                    }
                    Menu {
                        Picker("Author", selection: $filterAuthor) {
                            Text("All").tag(String?.none)
                            ForEach(allAuthors, id: \.self) { author in
                                Text(author).tag(String?.some(author))
                            }
                        }
                        Button("Clear author") { filterAuthor = nil }
                    } label: {
                        Label(filterAuthor.map { "Author: \($0)" } ?? "Author", systemImage: "person")
                    }
                    Menu {
                        Picker("Genre", selection: $filterGenre) {
                            Text("All").tag(String?.none)
                            ForEach(allGenres, id: \.self) { genre in
                                Text(genre).tag(String?.some(genre))
                            }
                        }
                        Button("Clear genre") { filterGenre = nil }
                    } label: {
                        Label(filterGenre.map { "Genre: \($0)" } ?? "Genre", systemImage: "tag")
                    }
                    Menu {
                        Button {
                            toggleSortField(.title)
                        } label: {
                            Label(sortFieldLabel(.title), systemImage: isSortField(.title) ? "checkmark" : "arrow.up.arrow.down")
                        }
                        Button {
                            toggleSortField(.author)
                        } label: {
                            Label(sortFieldLabel(.author), systemImage: isSortField(.author) ? "checkmark" : "arrow.up.arrow.down")
                        }
                        Button {
                            toggleSortField(.dateAdded)
                        } label: {
                            Label(sortFieldLabel(.dateAdded), systemImage: isSortField(.dateAdded) ? "checkmark" : "arrow.up.arrow.down")
                        }
                        Button("Tap a field again to reverse the order") {}
                            .disabled(true)
                            .accessibilityHidden(true)
                    } label: {
                        Label(sortOrder.displayName, systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $filteredSheet) { sheet in
            FilteredBooksSheet(sheet: sheet)
        }
        .sheet(isPresented: $showGenreCleanup) {
            GenreCleanupView(books: visibleBooks)
        }
        .sheet(isPresented: $showShelfCategories) {
            ShelfCategoriesView(books: visibleBooks)
        }
        .toolbar(isScrolled ? .hidden : .visible, for: .tabBar)
        .onChange(of: viewMode) { isScrolled = false }
        .onChange(of: grouping) { isScrolled = false }
        // (Re)build the canonical shelf plan whenever genre grouping is used.
        // Fingerprint gating means no AI call unless the library's tag set
        // actually changed since the last valid plan.
        .task(id: grouping) {
            await refreshShelfPlanIfNeeded()
        }
        .sheet(isPresented: $showAdd) {
            AddBookView()
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

    /// The AI genre-maintenance actions (clean up genres, reorganize shelves)
    /// as a visible capsule. Hidden from the toolbar on purpose — see the
    /// content-area note in `body`.
    private var aiToolsMenu: some View {
        Menu {
            Button("Clean up genres…") { showGenreCleanup = true }
            Button("Reorganize shelves…") { showShelfCategories = true }
        } label: {
            Label("AI tools", systemImage: "sparkles")
                .font(.footnote.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.thinMaterial)
                .clipShape(Capsule())
        }
    }


    // MARK: - Grid

    private var gridView: some View {
        if grouping == .none {
            return AnyView(
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                        ForEach(filteredBooks) { book in
                            NavigationLink {
                                BookDetailView(book: book)
                            } label: {
                                BookGridCell(book: book, showAddedDate: sortOrder.sortsByDate)
                            }
                            .buttonStyle(.plain)
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
        } else if grouping == .genre, genreSections != nil {
            return AnyView(genreSectionGrid)
        } else {
            let grouped = Dictionary(grouping: filteredBooks) { book in
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
                                        NavigationLink {
                                            BookDetailView(book: book)
                                        } label: {
                                            BookGridCell(book: book, showAddedDate: sortOrder.sortsByDate)
                                        }
                                        .buttonStyle(.plain)
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

    private var genreSectionGrid: some View {
        let sections = genreSections ?? []
        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.category) { section in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                            ForEach(section.books) { book in
                                NavigationLink {
                                    BookDetailView(book: book)
                                } label: {
                                    BookGridCell(book: book, showAddedDate: sortOrder.sortsByDate)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    } header: {
                        Text(section.category)
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
    }

    // MARK: - List

    private var listView: some View {
        if grouping == .none {
            return AnyView(List(filteredBooks) { book in
                NavigationLink {
                    BookDetailView(book: book)
                } label: {
                    BookListRow(book: book, showAddedDate: sortOrder.sortsByDate)
                }
            })
        } else if grouping == .genre, genreSections != nil {
            let sections = genreSections ?? []
            return AnyView(List {
                ForEach(sections, id: \.category) { section in
                    Section(section.category) {
                        ForEach(section.books) { book in
                            NavigationLink {
                                BookDetailView(book: book)
                            } label: {
                                BookListRow(book: book)
                            }
                        }
                    }
                }
            })
        } else {
            let grouped = Dictionary(grouping: filteredBooks) { book in
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
                                BookListRow(book: book)
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
        case .genre: return book.genres.first
        case .none: return nil
        }
    }

    private var hasActiveFilters: Bool {
        grouping != .none || filterAuthor != nil || filterGenre != nil
    }

    private var activeFiltersBar: some View {
        HStack(spacing: 10) {
            if grouping != .none {
                chip("Grouped by \(grouping.displayName)", systemImage: "rectangle.3.group") {
                    grouping = .none
                }
            }
            if let filterAuthor {
                chip("Author: \(filterAuthor)", systemImage: "person") {
                    self.filterAuthor = nil
                }
            }
            if let filterGenre {
                chip("Genre: \(filterGenre)", systemImage: "tag") {
                    self.filterGenre = nil
                }
            }
            Spacer()
            Button("Clear all") {
                grouping = .none
                filterAuthor = nil
                filterGenre = nil
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncCoverView(url: CoverImageStore.displayURL(forCover: book.coverImageURL), width: 92, height: 134)
                .overlay(alignment: .topLeading) {
                    if book.isLoaned {
                        LoanBadge()
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
            Image(systemName: book.statusEnum.systemImage)
                .foregroundStyle(.secondary)
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
