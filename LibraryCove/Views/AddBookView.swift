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

/// Snapshots a batch of books set to the import/edit flow. Wrapping the array
/// in an `Identifiable` value lets the flow present via `.sheet(item:)` (the
/// same reliable pattern the scanner's review sheet uses) instead of an
/// `isPresented` binding whose content closure can capture a stale queue.
private struct ImportQueueDispatch: Identifiable {
    let id = UUID()
    let books: [CatalogBook]
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
    /// Title of the most recently added book, surfaced as a confirmation.
    @State private var addedBookTitle: String?
    /// Staged by the manual-entry form's onAdded callback; promoted to
    /// addedBookTitle only after the sheet has fully dismissed, so the alert
    /// never presents while a dismissal transition is still running.
    @State private var pendingAddedTitle: String?
    @State private var descriptionSource: DescriptionSource = .openlibrary
    @State private var selectedIDs = Set<String>()
    @State private var importDispatch: ImportQueueDispatch?
    @State private var existingIsbns = Set<String>()
    @State private var existingBookNames = [String: String]()
    @State private var showScanReview = false
    /// Set when the user picks "Add manually" — presents the book form on a
    /// blank catalog stub.
    @State private var manualEntry: CatalogBook?
    @State private var searchHistory: [String] = loadSearchHistory()
    @StateObject private var scanQueue = ScanQueueStore.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if scanQueue.count > 0 {
                    Button {
                        resumePendingScans()
                    } label: {
                        HStack {
                            Label("\(scanQueue.count) scanned book\(scanQueue.count == 1 ? "" : "s") not yet added",
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
                    .accessibilityValue("\(scanQueue.importableBooks.count) ready, \(scanQueue.isProcessing ? "processing" : "idle")")
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
                Menu {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan ISBN", systemImage: "barcode.viewfinder")
                    }
                    Button {
                        manualEntry = CatalogBook.manualEntry()
                    } label: {
                        Label("Add manually", systemImage: "square.and.pencil")
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                if !selectedIDs.isEmpty {
                    Button("Add selected (\(selectedIDs.count))") {
                        startImportFlow()
                    }
                }
            }
        }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerFlow(existingIsbns: existingIsbns, existingBookNames: existingBookNames, onFinished: {
                    showScanner = false
                    dismiss()
                })
                .onAppear { buildExistingSet() }
            }
            .sheet(isPresented: $showScanReview, onDismiss: { buildExistingSet() }) {
                ScanQueueReviewListView(onAllImported: {
                    showScanReview = false
                    dismiss()
                })
            }
            .sheet(item: $importDispatch) { dispatch in
                BookImportFlow(queue: dispatch.books,
                               onEachSaved: { id in scanQueue.remove(id: id) },
                               onDone: {
                    importDispatch = nil
                    showScanner = false
                    dismiss()
                })
            }
            .sheet(item: $manualEntry, onDismiss: {
                buildExistingSet()
                addedBookTitle = pendingAddedTitle
                pendingAddedTitle = nil
            }) { stub in
                NavigationStack {
                    BookFormView(catalog: stub, existing: nil,
                                 onAdded: { pendingAddedTitle = $0 },
                                 dismissOnSave: true)
                    .navigationTitle("Add a book")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .onAppear {
                buildExistingSet()
                ScanQueueStore.shared.startProcessingIfNeeded()
            }
            .alert("Book added",
                   isPresented: Binding(
                       get: { addedBookTitle != nil },
                       set: { if !$0 { addedBookTitle = nil } }
                   )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("“\(addedBookTitle ?? "")” was added successfully.")
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
                    Section {
                        Button {
                            manualEntry = CatalogBook.manualEntry()
                        } label: {
                            HStack {
                                Image(systemName: "square.and.pencil")
                                    .foregroundStyle(.blue)
                                Text("Add manually")
                                Spacer()
                            }
                        }
                    } footer: {
                        Text("Add a book by typing its details yourself — no ISBN or catalog search needed.")
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

/// Full-screen scanner. The camera caches every ISBN into the background scan
/// queue immediately — no scan ever waits on a network lookup, so the user can
/// run through a whole stack of books and review them afterward.
private struct ScannerFlow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var queue = ScanQueueStore.shared
    @State private var rescanKey = 0
    @State private var selectedScanItemID: String?
    @State private var flashISBN: String?
    @State private var flash = false
    @State private var flashPulse = false
    @State private var duplicateScan: DuplicateScan?
    @State private var importQueue: [CatalogBook] = []
    @State private var isImporting = false
    let existingIsbns: Set<String>
    let existingBookNames: [String: String]
    let onFinished: () -> Void

    /// A barcode scan rejected because a library book already has that ISBN.
    private struct DuplicateScan: Equatable {
        let isbn: String
        /// Title of the matching library book, when one was resolvable.
        let name: String?
    }

    var body: some View {
        Group {
            if isImporting {
                importFlow
            } else {
                cameraView
            }
        }
        .sheet(item: selectedScanItem) { item in
            ScanQueueItemReviewView(itemID: item.id)
        }
        .onAppear {
            seedScannedBooksForTesting()
            queue.startProcessingIfNeeded()
            // UI-test seam: feed a barcode through the real handleCode path
            // (the camera produces no frames in the simulator, and the
            // duplicate-alert logic lives in handleCode). Slight delay so
            // the alert presents after the full-screen cover finishes.
            if let code = ProcessInfo.processInfo.environment["UI_TEST_SCAN_CODE"], !code.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weakSelfCode = code] in
                    self.handleCode(weakSelfCode)
                }
            }
        }
    }

    private var selectedScanItem: Binding<ScanQueueItem?> {
        Binding(
            get: { selectedScanItemID.flatMap { queue.item(id: $0) } },
            set: { selectedScanItemID = $0?.id }
        )
    }

    /// The import/edit/swipe screen, swapped in place of the camera so we never
    /// present a modal on top of the full-screen camera (that was unreliable).
    private var importFlow: some View {
        BookImportFlow(queue: importQueue,
                       onEachSaved: { id in queue.remove(id: id) },
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
        .alert(
            "Already in library",
            isPresented: .init(get: { duplicateScan != nil },
                               set: { if !$0 { duplicateScan = nil } })
        ) {
            Button("Add another copy") {
                // Treat the scan as a normal enqueue: the ISBN resolves in the
                // background and shows up in the scan strip/review. When it's
                // saved, the form's existing duplicate detection offers the
                // "add another copy / keep existing / cancel" choice — so no
                // special copy path is needed here.
                if let hit = duplicateScan {
                    queue.enqueue(isbn: hit.isbn)
                }
            }
            Button("OK", role: .cancel) {
                // "Skip this scan" must actually skip: discard any queued
                // scan of this ISBN (including stale entries from earlier
                // sessions) so it never resurfaces in the pending list.
                if let hit = duplicateScan {
                    queue.removeISBN(hit.isbn)
                }
            }
        } message: {
            if let hit = duplicateScan {
                if let name = hit.name, !name.isEmpty {
                    Text("“\(name)” (ISBN \(hit.isbn)) is already in your library. Add another copy from the scan list, or skip this scan.")
                } else {
                    Text("ISBN \(hit.isbn) is already in your library. Add another copy from the scan list, or skip this scan.")
                }
            }
        }
    }

    private var scannedBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(queue.items.isEmpty ? "No books scanned yet" : "\(queue.count) scanned")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Tap a book to review it")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !queue.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(queue.items) { item in
                            let title = item.book?.title.isEmpty == false ? item.book!.title : "ISBN \(item.isbn)"
                            Button {
                                selectedScanItemID = item.id
                            } label: {
                                ScanItemThumbnail(item: item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Review \(title)")
                        }
                    }
                }
                .frame(height: 64)
            }
            Button {
                importQueue = queue.importableBooks
                isImporting = true
            } label: {
                Label("Add all", systemImage: "plus")
                    .font(.footnote)
                    .fontWeight(.semibold)
            }
            .disabled(!queue.hasImportable)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// UI-test seam: seed already-looked-up scanned books from the launch
    /// environment so the "Add all" hand-off is testable without a camera.
    private func seedScannedBooksForTesting() {
        guard let raw = ProcessInfo.processInfo.environment["UI_TEST_SCANNED_BOOKS"],
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([CatalogBook].self, from: data) else { return }
        queue.replaceAll(with: list)
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
        // Reject a scan whose ISBN is already in the library before it's queued.
        // Resolved LIVE against the store: the existingIsbns snapshot passed
        // through the fullScreenCover content closure is captured when the
        // cover is built and can be stale (missed books added moments earlier
        // — the duplicate alert silently became a quiet enqueue).
        let normalized = Book.normalizedISBN(code)
        let existing: Book? = normalized.flatMap { key in
            let descriptor = LibraryScope.shared.activeBooksDescriptor(context: modelContext)
            let books = (try? modelContext.fetch(descriptor)) ?? []
            return books.first { Book.normalizedISBN($0.isbn) == key }
        }
        if let normalized, let hit = existing {
            duplicateScan = DuplicateScan(isbn: normalized, name: hit.title.isEmpty ? nil : hit.title)
        } else {
            // Cache the ISBN immediately; the background processor looks it up.
            queue.enqueue(isbn: code)
        }
        let flashCode = Book.normalizedISBN(code) ?? code
        flashISBN = flashCode
        withAnimation(.easeOut(duration: 0.2)) {
            flash = true
        }
        // Re-arm the camera instantly — scanning never waits on a lookup.
        rescanKey += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.25)) {
                flash = false
            }
        }
    }
}

/// Detail/review for a single scanned item, reached by tapping it in the scan
/// strip. Importable items open the full edit+delete form; items still being
/// looked up show their status with the option to remove (or retry a failure).
private struct ScanQueueItemReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var queue = ScanQueueStore.shared
    let itemID: String

    var body: some View {
        Group {
            if let item = queue.item(id: itemID), let book = item.book {
                // Full editable details for the scanned book, including the
                // trash action (BookFormView's delete/duplicate handling).
                NavigationStack {
                    BookFormView(catalog: book, existing: nil,
                                 onSaved: { finish(itemID) },
                                 onDeleted: { finish(itemID) },
                                 dismissOnSave: false)
                        .navigationTitle("Review scanned book")
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else if let item = queue.item(id: itemID) {
                NavigationStack {
                    statusView(item)
                }
            } else {
                // Item was removed while the sheet was open.
                Color.clear.onAppear { dismiss() }
            }
        }
    }

    private func statusView(_ item: ScanQueueItem) -> some View {
        VStack(spacing: 20) {
            Spacer()
            switch item.status {
            case .queued, .processing:
                ProgressView()
                    .controlSize(.large)
                Text("Looking up ISBN \(item.isbn)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text("Couldn't reach the catalog for ISBN \(item.isbn).")
                    .font(.callout)
                if let error = item.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    queue.retry(id: itemID)
                } label: {
                    Label("Retry lookup", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            case .ready, .unavailable:
                EmptyView()
            }
            Button("Remove from scan list", role: .destructive) {
                finish(itemID)
            }
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("ISBN \(item.isbn)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func finish(_ id: String) {
        queue.remove(id: id)
        dismiss()
    }
}

/// Compact cover thumbnail with a status overlay, shared by the scanner strip
/// and the pending-scan review list.
private struct ScanItemThumbnail: View {
    let item: ScanQueueItem

    var body: some View {
        AsyncCoverView(url: item.book.flatMap { CoverImageStore.displayURL(forCover: $0.primaryCoverURL) },
                       width: 44, height: 64)
        .overlay {
            switch item.status {
            case .queued, .processing:
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.35))
                ProgressView()
                    .tint(.white)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .background(Circle().fill(.white))
            case .ready:
                EmptyView()
            case .unavailable:
                EmptyView()
            }
        }
        .overlay(alignment: .bottom) {
            // Not-found scans have no cover; label them so they're clearly
            // awaiting manual details.
            if item.status == .unavailable || (item.book?.title.isEmpty ?? false) {
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
}

/// Persistent review of everything the user scanned but hasn't added yet — the
/// Add-screen banner always opens here, whether lookups finished, are still
/// running, or failed. Every queued scan is visible with its status; rows open
/// the same review/delete sheet as the scanner strip, and "Add all" hands
/// eligible books to the import pager.
private struct ScanQueueReviewListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var queue = ScanQueueStore.shared
    @State private var selectedScanItemID: String?
    @State private var addAllDispatch: ImportQueueDispatch?
    var onAllImported: () -> Void = {}

    var body: some View {
        NavigationStack {
            Group {
                if queue.items.isEmpty {
                    ContentUnavailableView(
                        "No pending scans",
                        systemImage: "books.vertical",
                        description: Text("Scanned books that aren't in your library yet appear here.")
                    )
                } else {
                    List {
                        ForEach(queue.items) { item in
                            Button {
                                selectedScanItemID = item.id
                            } label: {
                                row(item)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(reviewLabel(for: item))
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                queue.remove(id: queue.items[index].id)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Pending scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add all") {
                        addAllDispatch = ImportQueueDispatch(books: queue.importableBooks)
                    }
                    .disabled(!queue.hasImportable)
                }
            }
        }
        .sheet(item: $addAllDispatch) { dispatch in
            BookImportFlow(queue: dispatch.books,
                           onEachSaved: { id in queue.remove(id: id) },
                           onDone: {
                               addAllDispatch = nil
                               onAllImported()
                           })
        }
        .sheet(item: selectedScanItem) { item in
            ScanQueueItemReviewView(itemID: item.id)
        }
    }

    private var selectedScanItem: Binding<ScanQueueItem?> {
        Binding(
            get: { selectedScanItemID.flatMap { queue.item(id: $0) } },
            set: { selectedScanItemID = $0?.id }
        )
    }

    private func reviewLabel(for item: ScanQueueItem) -> String {
        if let title = item.book?.title, !title.isEmpty {
            return "Review \(title)"
        }
        return "Review ISBN \(item.isbn)"
    }

    private func row(_ item: ScanQueueItem) -> some View {
        HStack(spacing: 12) {
            ScanItemThumbnail(item: item)
                .frame(width: 44, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                if let title = item.book?.title, !title.isEmpty {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    switch item.status {
                    case .queued, .processing:
                        Text("Looking up ISBN \(item.isbn)…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    case .failed:
                        Text("Lookup failed")
                            .font(.body)
                            .foregroundStyle(.orange)
                    case .unavailable:
                        Text("Add details manually")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    case .ready:
                        Text("ISBN \(item.isbn)")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.book?.authorsText ?? "ISBN \(item.isbn)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
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
        let books = results.filter { selectedIDs.contains($0.id) }
        selectedIDs = []
        guard !books.isEmpty else { return }
        importDispatch = ImportQueueDispatch(books: books)
    }
}

struct BookImportFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var remaining: [CatalogBook] = []
    @State private var currentID = ""
    @State private var showDeleteConfirmation = false
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
                                    dismissOnSave: false,
                                    showsToolbarDelete: false)
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
                // One trash for the whole flow, owned here — not one per page.
                // Pages swap during a swipe transition, so per-page toolbar
                // items flashed a duplicate delete button in the nav bar.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .alert("Delete this book?", isPresented: $showDeleteConfirmation) {
                    Button("Delete", role: .destructive) {
                        handleSaved(currentID)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This book won't be added to your library.")
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
        let descriptor = LibraryScope.shared.activeBooksDescriptor(context: modelContext)
        do {
            let books = try modelContext.fetch(descriptor)
            existingIsbns = Set(books.compactMap { Book.normalizedISBN($0.isbn) })
            var names: [String: String] = [:]
            for book in books {
                if let normalized = Book.normalizedISBN(book.isbn), !book.title.isEmpty {
                    names[normalized] = book.title
                }
            }
            existingBookNames = names
        } catch {
            existingIsbns = []
            existingBookNames = [:]
        }
    }

    private func resumePendingScans() {
        // Always open the pending-scan review — whether a scan finished looking
        // up, is still resolving, or failed. Every entry is actionable there
        // (review/delete/retry, or "Add all" for the import pager), so tapping
        // the banner never silently does nothing.
        showScanReview = true
    }
}
