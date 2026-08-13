import SwiftUI
import SwiftData

private func loadSearchHistory() -> [String] {
    guard let data = UserDefaults.standard.data(forKey: "searchHistory"),
          let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return list
}

private func saveSearchHistory(_ history: [String]) {
    if let data = try? JSONEncoder().encode(history) {
        UserDefaults.standard.set(data, forKey: "searchHistory")
    }
}

/// Add a book: search the catalog, scan an ISBN, or import a result.
struct AddBookView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: CatalogService = OpenLibraryService()
    @State private var searchText = ""
    @State private var results: [CatalogBook] = []
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showScanner = false
    @State private var descriptionSource: DescriptionSource = .openlibrary
    @State private var selectedIDs = Set<String>()
    @State private var importQueue = [CatalogBook]()
    @State private var showImportFlow = false
    @State private var existingIsbns = Set<String>()
    @State private var searchHistory: [String] = loadSearchHistory()
    @State private var pendingCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if pendingCount > 0 {
                    Button {
                        resumePendingScans()
                    } label: {
                        HStack {
                            Label("\(pendingCount) scanned book\(pendingCount == 1 ? "" : "s") not yet added",
                                  systemImage: "barcode.viewfinder")
                                .font(.body)
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)
                }
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
                ScannerFlow(existingIsbns: existingIsbns, onFinished: {
                    showScanner = false
                    dismiss()
                })
            }
            .sheet(isPresented: $showImportFlow) {
                BookImportFlow(queue: importQueue,
                               onEachSaved: { id in PendingScanStore.remove(id: id) },
                               onDone: {
                    showImportFlow = false
                    showScanner = false
                    dismiss()
                })
            }
            .onAppear {
                buildExistingSet()
                loadPendingScans()
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
                    hasSearched = false
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
                } else if hasSearched {
                    ContentUnavailableView(
                        "No books found",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different title or author.")
                    )
                }
            } else {
                if searchText.isEmpty && !isSearching {
                    if !searchHistory.isEmpty {
                        Section {
                            ForEach(searchHistory, id: \.self) { query in
                                Button {
                                    runSearch(query)
                                } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                            .foregroundStyle(.secondary)
                                        Text(query)
                                        Spacer()
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("Recent searches")
                                Spacer()
                                Button("Clear") {
                                    searchHistory = []
                                    saveSearchHistory([])
                                }
                            }
                        }
                    }
                } else {
                    ForEach(results) { result in
                    Button {
                        toggleSelection(result)
                    } label: {
                        CatalogRow(book: result)
                            .overlay(alignment: .leading) {
                                if existingIsbns.contains(Book.normalizedISBN(result.isbn) ?? "") {
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
        }
        .listStyle(.plain)
    }

    private func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            hasSearched = false
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false; hasSearched = true }
        do {
            results = try await catalog.search(query: query, preferred: descriptionSource)
        } catch {
            results = []
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
        recordSearch(query)
    }

    private func runSearch(_ query: String) {
        searchText = query
        results = []
        hasSearched = false
        Task { await performSearch() }
    }

    private func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = searchHistory
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        searchHistory = Array(history.prefix(10))
        saveSearchHistory(searchHistory)
    }

}

/// Full-screen scanner that accumulates detected barcodes into a list.
private struct ScannerFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: CatalogService = OpenLibraryService()
    @State private var scannedBooks: [CatalogBook] = []
    @State private var isLookup = false
    @State private var lookupError: String?
    @State private var rescanKey = 0
    @State private var pendingDeleteID: String?
    @State private var flashISBN: String?
    @State private var flash = false
    @State private var flashPulse = false
    @State private var lookupAlertMessage: String?
    @State private var showLookupAlert = false
    @State private var importQueue: [CatalogBook] = []
    @State private var isImporting = false
    let existingIsbns: Set<String>
    let onFinished: () -> Void

    var body: some View {
        Group {
            if isImporting {
                importFlow
            } else {
                cameraView
            }
        }
        .onAppear {
            seedScannedBooksForTesting()
        }
    }

    /// The import/edit/swipe screen, swapped in place of the camera so we never
    /// present a modal on top of the full-screen camera (that was unreliable).
    private var importFlow: some View {
        BookImportFlow(queue: importQueue,
                       onEachSaved: { id in PendingScanStore.remove(id: id) },
                       onDone: {
                           onFinished()
                       })
        .overlay(alignment: .topLeading) {
            Button {
                isImporting = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.bold())
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .foregroundStyle(.primary)
            }
            .padding(.leading, 8)
            .accessibilityLabel("Back to scanning")
        }
    }

    private var cameraView: some View {
        ZStack {
            ISBNScannerView(onCode: handleCode, rescanKey: rescanKey)
                .ignoresSafeArea()
            scanFrameFlash
            VStack {
                Spacer()
                Text("Point the camera at a book's barcode")
                    .font(.callout)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 40)
            }
            VStack {
                Spacer()
                scannedBar
                    .padding(.horizontal)
                    .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .topLeading) {
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
            .accessibilityLabel("Close scanner")
        }
        .confirmationDialog(
            "Remove scanned book?",
            isPresented: .init(get: { pendingDeleteID != nil },
                               set: { if !$0 { pendingDeleteID = nil } }),
            presenting: pendingDeleteID
        ) { id in
            Button("Remove", role: .destructive) {
                scannedBooks.removeAll { $0.id == id }
                PendingScanStore.remove(id: id)
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: { _ in
            Text("This book won't be added unless you scan it again.")
        }
        .alert(
            "Scan result",
            isPresented: $showLookupAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lookupAlertMessage ?? "The book lookup failed. Try again.")
        }
    }

    private var scannedBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scannedBooks.isEmpty ? "No books scanned yet" : "\(scannedBooks.count) scanned")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Tap a book to remove it")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !scannedBooks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(scannedBooks) { book in
                            Button {
                                pendingDeleteID = book.id
                            } label: {
                                AsyncCoverView(url: CoverImageStore.displayURL(forCover: book.primaryCoverURL), width: 44, height: 64)
                                    .overlay(alignment: .topLeading) {
                                        if existingIsbns.contains(Book.normalizedISBN(book.isbn) ?? "") {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .overlay(alignment: .bottom) {
                                        // Not-found scans have no cover; label them
                                        // so they're clearly awaiting manual details.
                                        if book.title.isEmpty {
                                            Text("manual")
                                                .font(.system(size: 9, weight: .semibold))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(.black.opacity(0.65))
                                                .foregroundStyle(.white)
                                                .clipShape(Capsule())
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 64)
            } else if isLookup {
                ProgressView().controlSize(.small)
            } else if let error = lookupError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Button {
                importQueue = scannedBooks
                isImporting = true
            } label: {
                Label("Add all", systemImage: "plus")
                    .font(.footnote)
                    .fontWeight(.semibold)
            }
            .disabled(scannedBooks.isEmpty || isLookup)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// UI-test seam: seed scanned books from the launch environment so the
    /// "Add all" hand-off to the import flow is testable without a camera.
    private func seedScannedBooksForTesting() {
        guard let raw = ProcessInfo.processInfo.environment["UI_TEST_SCANNED_BOOKS"],
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([CatalogBook].self, from: data) else { return }
        scannedBooks = list
        for book in list {
            PendingScanStore.append(book)
        }
    }

    private var scanFrameFlash: some View {
        Group {
            if flash, let isbn = flashISBN {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.green, lineWidth: 3)
                            .frame(width: 230, height: 230)
                            .overlay {
                                Image(systemName: "barcode.viewfinder")
                                    .font(.system(size: 52))
                                    .foregroundStyle(.green)
                            }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("ISBN \(isbn) detected")
                            .font(.headline.monospacedDigit())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .scaleEffect(flashPulse ? 1.0 : 0.94)
                .opacity(flashPulse ? 1.0 : 0.75)
                .shadow(color: .green.opacity(flashPulse ? 0.9 : 0.35), radius: flashPulse ? 24 : 10)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                        flashPulse = true
                    }
                }
                .onDisappear {
                    flashPulse = false
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func handleCode(_ code: String) {
        lookupError = nil
        isLookup = true
        flashISBN = code
        withAnimation(.easeOut(duration: 0.2)) {
            flash = true
        }
        // Reject a scan whose ISBN is already in the library before it's queued.
        if existingIsbns.contains(Book.normalizedISBN(code) ?? "") {
            lookupAlertMessage = "ISBN \(code) is already in your library. It wasn't added to the scan list."
            showLookupAlert = true
            isLookup = false
            rescanKey += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.25)) {
                    flash = false
                }
            }
            return
        }
        Task { @MainActor in
            do {
                if let book = try await catalog.lookup(isbn: code, preferred: .openlibrary) {
                    scannedBooks.removeAll { $0.id == book.id }
                    scannedBooks.append(book)
                    PendingScanStore.append(book)
                } else {
                    // No catalog entry: still let the user add the book, but
                    // the details are entered by hand. Surface it clearly — a
                    // bare generic cover in the scan list is too easy to miss.
                    let stub = CatalogBook.manualStub(isbn: code)
                    scannedBooks.removeAll { $0.id == stub.id }
                    scannedBooks.append(stub)
                    PendingScanStore.append(stub)
                    lookupAlertMessage = "No online details for this ISBN. It was added to the scan list — when you tap Add all, enter the title and author manually."
                    showLookupAlert = true
                }
            } catch {
                lookupError = "Lookup failed: \(error.localizedDescription)"
                lookupAlertMessage = "Lookup failed: \(error.localizedDescription). Try again."
                showLookupAlert = true
            }
            isLookup = false
            rescanKey += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.25)) {
                    flash = false
                }
            }
        }
    }
}



private struct CatalogRow: View {
    let book: CatalogBook

    var body: some View {
        HStack(spacing: 12) {
            AsyncCoverView(url: CoverImageStore.displayURL(forCover: book.primaryCoverURL), width: 52, height: 76)
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
        if let url {
            // Locally stored covers (data: URLs and on-disk file: URLs) render
            // synchronously; only truly remote URLs hit AsyncImage.
            if url.absoluteString.hasPrefix("data:") || url.isFileURL {
                if let ui = image(from: url) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Placeholder
                }
            } else {
                AsyncImage(url: url, transaction: Transaction()) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Placeholder
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        } else {
            Placeholder
        }
    }

    private func image(from url: URL) -> UIImage? {
        if url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        }
        let str = url.absoluteString
        return CoverImageStore.data(fromDataURL: str).flatMap(UIImage.init(data:))
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
    @State private var currentID = ""
    var onEachSaved: (String) -> Void = { _ in }
    var onDone: () -> Void = {}

    init(queue: [CatalogBook], onEachSaved: @escaping (String) -> Void = { _ in }, onDone: @escaping () -> Void = {}) {
        self.onEachSaved = onEachSaved
        self.onDone = onDone
        _remaining = State(initialValue: queue)
        _currentID = State(initialValue: queue.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            if remaining.isEmpty {
                ContentUnavailableView(
                    "All books added",
                    systemImage: "checkmark",
                    description: Text("There are no more books to import.")
                )
                .navigationTitle("All books added")
                .navigationBarTitleDisplayMode(.inline)
            } else {
                TabView(selection: $currentID) {
                    ForEach(remaining, id: \.id) { book in
                        BookFormView(catalog: book, existing: nil,
                                    onSaved: { handleSaved(book.id) },
                                    onDeleted: { handleSaved(book.id) },
                                    dismissOnSave: false)
                            .tag(book.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .navigationTitle("\(remaining.count) remaining")
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
    }

    /// Removes a finished book from the queue. Called for both saved books
    /// and books discarded via "Delete" — either way the book leaves the
    /// queue and its pending-scan record is cleared.
    private func handleSaved(_ id: String) {
        remaining.removeAll { $0.id == id }
        onEachSaved(id)
        if remaining.isEmpty {
            onDone()
        } else {
            currentID = remaining.first?.id ?? ""
        }
    }
}


extension AddBookView {
    private func buildExistingSet() {
        let descriptor = FetchDescriptor<Book>()
        do {
            let books = try modelContext.fetch(descriptor)
            existingIsbns = Set(books.compactMap { Book.normalizedISBN($0.isbn) })
        } catch {
            existingIsbns = []
        }
    }

    private func loadPendingScans() {
        pendingCount = PendingScanStore.load().count
    }

    private func resumePendingScans() {
        importQueue = PendingScanStore.load()
        pendingCount = 0
        showImportFlow = true
    }
}
