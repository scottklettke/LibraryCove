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

/// Main library screen: all books with cover grid, list, by-location, and dashboard views.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.title) private var books: [Book]

    @State private var viewMode: LibraryViewMode = .grid
    @State private var searchText = ""
    @State private var showAdd = false
    @State private var grouping: LibraryGrouping = .none
    @State private var filterAuthor: String?
    @State private var filterGenre: String?

    private var filteredBooks: [Book] {
        let visible = books.filter { $0.status != BookStatus.donated.rawValue }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched: [Book]
        if query.isEmpty {
            searched = visible
        } else {
            searched = visible.filter { book in
                let haystack = [
                    book.title,
                    book.authorsText,
                    book.genres.joined(separator: " "),
                    book.physicalLocation ?? "",
                    book.bookDescription ?? "",
                    book.notes.map(\.content).joined(separator: " ")
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
        return result
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
        Group {
            switch viewMode {
            case .grid: gridView
            case .list: listView
            case .byLocation: byLocationView
            case .dashboard: dashboardView
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                modePicker
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
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddBookView()
        }
        .searchable(text: $searchText, prompt: "Search title, author, notes…")
        .overlay {
            if books.isEmpty {
                ContentUnavailableView(
                    "Your library is empty",
                    systemImage: "books.vertical",
                    description: Text("Add your first book from the catalog or scan an ISBN.")
                )
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
            return AnyView(ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                    ForEach(filteredBooks) { book in
                        NavigationLink {
                            BookDetailView(book: book)
                        } label: {
                            BookGridCell(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            })
        } else {
            let grouped = Dictionary(grouping: filteredBooks) { book in
                groupKey(for: book)
            }
            let keys = grouped.keys.sorted {
                ($0 ?? "") < ($1 ?? "")
            }
            return AnyView(ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(keys, id: \.self) { key in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                                ForEach(grouped[key] ?? []) { book in
                                    NavigationLink {
                                        BookDetailView(book: book)
                                    } label: {
                                        BookGridCell(book: book)
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
            })
        }
    }

    // MARK: - List

    private var listView: some View {
        if grouping == .none {
            return AnyView(List(filteredBooks) { book in
                NavigationLink {
                    BookDetailView(book: book)
                } label: {
                    BookListRow(book: book)
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

    // MARK: - By location

    private var byLocationView: some View {
        let grouped = Dictionary(grouping: filteredBooks, by: \.physicalLocation)
        return List {
            let locations = grouped.keys.sorted {
                ($0 ?? "") < ($1 ?? "")
            }
            ForEach(locations, id: \.self) { location in
                Section(location ?? "Unplaced") {
                    ForEach(grouped[location] ?? []) { book in
                        NavigationLink {
                            BookDetailView(book: book)
                        } label: {
                            BookListRow(book: book)
                        }
                    }
                }
            }
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
                LabeledContent("Loaned out", value: "\(libraryBooks.filter(\.isLoaned).count)")
                LabeledContent("Donated", value: "\(count(status: .donated))")
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

/// Grid cell: cover + short title.
struct BookGridCell: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncCoverView(url: book.coverImageURL.flatMap { URL(string: $0) }, width: 92, height: 134)
                .overlay(alignment: .topLeading) {
                    if book.isLoaned {
                        LoanBadge()
                    }
                }
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: 92, alignment: .leading)
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

    var body: some View {
        HStack(spacing: 12) {
            AsyncCoverView(url: book.coverImageURL.flatMap { URL(string: $0) }, width: 40, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                Text(book.authorsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
