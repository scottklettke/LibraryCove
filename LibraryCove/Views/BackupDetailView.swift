import SwiftUI
import SwiftData

/// Detail page for one backup: lists every book it contains (newest added
/// first) and offers to restore it — with the same add-new-only /
/// replace-whole-library choice as a zip-file import.
struct BackupDetailView: View {
    let backup: BackupStore.Item
    let modelContext: ModelContext
    /// Called after a restore completes so the presenter refreshes its list.
    var onRestored: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openLibraryTab) private var openLibraryTab

    @State private var books: [BookDTO]?
    @State private var loadError: String?
    @State private var showImportPreview = false
    @State private var archiveData: Data?
    @State private var isRestoring = false
    @State private var showDeleteConfirm = false

    var body: some View {
        Form {
            Section {
                Button {
                    loadAndPresentImport()
                } label: {
                    HStack {
                        Label("Restore this backup", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if isRestoring {
                            ProgressView()
                        }
                    }
                }
                .disabled(isRestoring || books == nil)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete backup", systemImage: "trash")
                }
            } header: {
                Text(backup.name)
            } footer: {
                Text("Restoring offers the same choice as importing a file: add only books you don't have, or replace the whole library with this backup.")
            }

            if let loadError {
                Section {
                    Text(loadError)
                        .foregroundStyle(.red)
                } header: {
                    Text("Couldn't read backup")
                }
            } else if let books {
                Section {
                    if books.isEmpty {
                        Text("This backup contains no books.")
                    } else {
                        ForEach(books, id: \.id) { book in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title)
                                    .font(.body)
                                Text(subtitle(for: book))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Books (\(books.count)) — newest added first")
                }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadBooks() }
        .sheet(isPresented: $showImportPreview) {
            if let archiveData {
                ImportPreviewView(
                    archiveData: archiveData,
                    sourceName: backup.name,
                    modelContext: modelContext
                ) { _ in
                    onRestored()
                    openLibraryTab()
                }
            }
        }
        .confirmationDialog(
            "Delete this backup?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete backup", role: .destructive) {
                BackupStore.delete(url: backup.url)
                onRestored()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(backup.name)” will be deleted. This cannot be undone.")
        }
    }

    private func subtitle(for book: BookDTO) -> String {
        var parts: [String] = []
        if !book.authors.isEmpty { parts.append(book.authors.joined(separator: ", ")) }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        parts.append("Added \(formatter.string(from: book.createdAt))")
        return parts.joined(separator: " · ")
    }

    private func loadBooks() {
        do {
            let data = try Data(contentsOf: backup.url)
            archiveData = data
            books = try LibraryDataService.archiveBooks(data: data)
        } catch {
            loadError = (error as? LibraryDataError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func loadAndPresentImport() {
        guard archiveData != nil else { loadBooks(); return }
        showImportPreview = true
    }
}
