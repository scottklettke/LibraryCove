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

/// Main library screen: all books with cover grid, list, by-location, and dashboard views.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.title) private var books: [Book]

    @State private var viewMode: LibraryViewMode = .grid
    @State private var searchText = ""
    @State private var showAdd = false

    private var filteredBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return books }
        return books.filter { book in
            let haystack = [
                book.title,
                book.authorsText,
                book.genres.joined(separator: " "),
                book.physicalLocation ?? "",
                book.notes.map(\.content).joined(separator: " ")
            ].joined(separator: " ").lowercased()
            return haystack.contains(query.lowercased())
        }
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
        ScrollView {
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
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - List

    private var listView: some View {
        List(filteredBooks) { book in
            NavigationLink {
                BookDetailView(book: book)
            } label: {
                BookListRow(book: book)
            }
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
        List {
            Section("Summary") {
                LabeledContent("Total books", value: "\(books.count)")
                LabeledContent("Reading", value: "\(count(status: .reading))")
                LabeledContent("To read", value: "\(count(status: .toRead))")
                LabeledContent("Completed", value: "\(count(status: .completed))")
                LabeledContent("Owned", value: "\(count(status: .owned))")
            }
            Section("By location") {
                let counts = Dictionary(grouping: books, by: \.physicalLocation)
                let locations = counts.keys.sorted {
                    ($0 ?? "") < ($1 ?? "")
                }
                ForEach(locations, id: \.self) { location in
                    LabeledContent(location ?? "Unplaced", value: "\(counts[location]?.count ?? 0)")
                }
            }
            Section("Recently added") {
                let recent = books.sorted { $0.createdAt > $1.createdAt }.prefix(10)
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
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: 92, alignment: .leading)
        }
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
        }
    }
}

extension BookStatus {
    var systemImage: String {
        switch self {
        case .reading: return "book.open"
        case .toRead: return "bookmark"
        case .completed: return "checkmark.circle"
        case .owned: return "books.vertical"
        case .donated: return "heart"
        }
    }
}
