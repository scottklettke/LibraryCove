import SwiftUI
import SwiftData

/// Add a book: search the catalog, scan an ISBN, or import a result.
struct AddBookView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: CatalogService = OpenLibraryService()
    @State private var searchText = ""
    @State private var results: [CatalogBook] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var selectedResult: CatalogBook?
    @State private var showScanner = false
    @State private var descriptionSource: DescriptionSource = .openlibrary
    @State private var selectedIDs = Set<String>()
    @State private var importQueue = [CatalogBook]()
    @State private var showImportFlow = false
    @State private var existingIsbns = Set<String>()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                resultsList
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Add a book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Menu {
                        Picker("Source", selection: $descriptionSource) {
                            ForEach(DescriptionSource.allCases) { source in
                                Text(source.displayName).tag(source)
                            }
                        }
                    } label: {
                        Label("Source", systemImage: "book.closed")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan ISBN", systemImage: "barcode.viewfinder")
                    }
                    if !selectedIDs.isEmpty {
                        Button("Add selected (\(selectedIDs.count))") {
                            startImportFlow()
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerFlow(existingIsbns: existingIsbns, onAddBook: { book in
                    selectedResult = book
                })
            }
            .navigationDestination(item: $selectedResult) { result in
                BookImportView(catalog: result)
            }
            .sheet(isPresented: $showImportFlow) {
                BookImportFlow(queue: importQueue, onDone: {
                    showImportFlow = false
                    dismiss()
                })
            }
            .onAppear {
                buildExistingSet()
            }
        }
    }


    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Title or author…", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .onSubmit { Task { await performSearch() } }
            if isSearching {
                ProgressView()
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var resultsList: some View {
        List {
            if results.isEmpty && !searchText.isEmpty {
                if isSearching {
                    ContentUnavailableView {
                        ProgressView()
                            .controlSize(.large)
                    } description: {
                        Text("Searching for \"\(searchText)\"…")
                    }
                } else {
                    ContentUnavailableView(
                        "No books found",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different title or author.")
                    )
                }
            } else {
                ForEach(results) { result in
                    Button {
                        toggleSelection(result)
                    } label: {
                        CatalogRow(book: result)
                            .overlay(alignment: .leading) {
                                if existingIsbns.contains(result.isbn ?? "") {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.green)
                                        .padding(8)
                                }
                            }
                            .overlay(alignment: .trailing) {
                                if selectedIDs.contains(result.id) {
                                    Image(systemName: "circle.inset.filled")
                                        .font(.title3)
                                        .foregroundStyle(.blue)
                                        .padding(8)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await catalog.search(query: query, preferred: descriptionSource)
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

}

/// Full-screen scanner that returns the first detected barcode.
private struct ScannerFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: CatalogService = OpenLibraryService()
    @State private var scannedCode: String?
    @State private var resultBook: CatalogBook?
    @State private var isLookup = false
    @State private var lookupError: String?
    @State private var rescanKey = 0
    let existingIsbns: Set<String>
    let onAddBook: (CatalogBook) -> Void

    var body: some View {
        ZStack {
            ISBNScannerView(onCode: handleCode, rescanKey: rescanKey)
                .ignoresSafeArea()
            VStack {
                Spacer()
                Text("Point the camera at a book's barcode")
                    .font(.callout)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 40)
            }
            if let book = resultBook {
                resultPanel(book)
            } else if isLookup {
                lookupPanel
            } else if let error = lookupError {
                errorPanel(error)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.bold())
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .padding()
        }
    }

    private func handleCode(_ code: String) {
        resultBook = nil
        lookupError = nil
        isLookup = true
        scannedCode = code
        Task {
            do {
                if let book = try await catalog.lookup(isbn: code, preferred: .openlibrary) {
                    resultBook = book
                } else {
                    lookupError = "No book found for ISBN \(code)."
                }
            } catch {
                lookupError = "Lookup failed: \(error.localizedDescription)"
            }
            isLookup = false
        }
    }

    private var lookupPanel: some View {
        VStack {
            ProgressView()
            Text("Looking up ISBN…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding()
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
            Button("Scan more") {
                lookupError = nil
                rescanKey += 1
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding()
    }

    private func resultPanel(_ book: CatalogBook) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                AsyncCoverView(url: book.primaryCoverURL.flatMap { URL(string: $0) }, width: 52, height: 76)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.headline)
                    Text(book.authorsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let year = book.publicationYear {
                        Text(verbatim: "\(year)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            HStack {
                if existingIsbns.contains(book.isbn ?? "") {
                    Label("Already in your library", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else {
                    Label("Not in your library", systemImage: "plus.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Button("Scan more") {
                    resultBook = nil
                    lookupError = nil
                    rescanKey += 1
                }
                Spacer()
                Button("Add to library") {
                    onAddBook(book)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding()
    }
}

private struct CatalogRow: View {
    let book: CatalogBook

    var body: some View {
        HStack(spacing: 12) {
            AsyncCoverView(url: book.primaryCoverURL.flatMap { URL(string: $0) }, width: 52, height: 76)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(book.authorsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let year = book.publicationYear {
                    Text(verbatim: "\(year)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Async-loads a cover image at a fixed size with placeholder fallback.
struct AsyncCoverView: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    init(url: URL?, width: CGFloat, height: CGFloat) {
        self.url = url
        self.width = width
        self.height = height
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
            if let url {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } placeholder: {
                    Placeholder
                }
            } else {
                Placeholder
            }
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }

    private var Placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "book.closed")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(.tertiary)
                .frame(width: width * 0.7, height: 2)
        }
        .frame(width: width, height: height)
    }
}

extension AddBookView {
    private func toggleSelection(_ result: CatalogBook) {
        if selectedIDs.contains(result.id) {
            selectedIDs.remove(result.id)
        } else {
            selectedIDs.insert(result.id)
        }
    }

    private func startImportFlow() {
        importQueue = results.filter { selectedIDs.contains($0.id) }
        selectedIDs = []
        showImportFlow = true
    }
}

struct BookImportFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var remaining: [CatalogBook] = []
    @State private var currentID: String?
    var onDone: () -> Void = {}

    init(queue: [CatalogBook], onDone: @escaping () -> Void = {}) {
        self.onDone = onDone
        _remaining = State(initialValue: queue)
        _currentID = State(initialValue: queue.first?.id)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $currentID) {
                ForEach(remaining, id: \.id) { book in
                    BookFormView(catalog: book, existing: nil,
                                 onSaved: { handleSaved(book.id) },
                                 dismissOnSave: false)
                        .tag(book.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .navigationTitle(remaining.isEmpty ? "All books added" : "\(remaining.count) remaining")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                if remaining.count > 1 {
                    HStack {
                        Image(systemName: "arrow.left")
                        Text("Swipe to browse \(remaining.count) books")
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                }
            }
        }
    }

    private func handleSaved(_ id: String) {
        remaining.removeAll { $0.id == id }
        if remaining.isEmpty {
            onDone()
        } else {
            currentID = remaining.first?.id
        }
    }
}

extension AddBookView {
    private func buildExistingSet() {
        let descriptor = FetchDescriptor<Book>()
        do {
            let books = try modelContext.fetch(descriptor)
            existingIsbns = Set(books.compactMap { $0.isbn })
        } catch {
            existingIsbns = []
        }
    }
}
