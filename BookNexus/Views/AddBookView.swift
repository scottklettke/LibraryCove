import SwiftUI
import SwiftData

/// Add a book: search the catalog, scan an ISBN, or import a result.
struct AddBookView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var catalog: CatalogService = OpenLibraryService()
    @State private var searchText = ""
    @State private var results: [CatalogBook] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var selectedResult: CatalogBook?
    @State private var scannedCode: String?
    @State private var showScanner = false

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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan ISBN", systemImage: "barcode.viewfinder")
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerFlow(scannedCode: $scannedCode)
            }
            .onChange(of: scannedCode) { _, code in
                guard let code else { return }
                scannedCode = nil
                Task { await handleScanned(code) }
            }
            .navigationDestination(item: $selectedResult) { result in
                BookImportView(catalog: result)
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
                ContentUnavailableView(
                    "No results",
                    systemImage: "books.vertical",
                    description: Text("Try a different title or author.")
                )
            } else {
                ForEach(results) { result in
                    Button {
                        selectedResult = result
                    } label: {
                        CatalogRow(book: result)
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
            results = try await catalog.search(query: query)
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    private func handleScanned(_ code: String) async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            if let book = try await catalog.lookup(isbn: code) {
                selectedResult = book
            } else {
                errorMessage = "No book found for ISBN \(code)."
            }
        } catch {
            errorMessage = "Lookup failed: \(error.localizedDescription)"
        }
    }

}

/// Full-screen scanner that returns the first detected barcode.
private struct ScannerFlow: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var scannedCode: String?

    var body: some View {
        ZStack {
            ISBNScannerView { code in
                scannedCode = code
                dismiss()
            }
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
