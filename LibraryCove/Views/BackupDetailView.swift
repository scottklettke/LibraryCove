import SwiftUI
import SwiftData

/// Detail page for one backup: lists every book it contains (newest added
/// first) and offers to restore it — with the same add-new-only /
/// replace-whole-library choice as a zip-file import. Backups are one
/// synced iCloud set; no per-provider switching is involved.
struct BackupDetailView: View {
    let backup: BackupStore.Item
    /// Called after a restore completes so the presenter refreshes its list.
    var onRestored: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openLibraryTab) private var openLibraryTab

    @State private var books: [BookDTO]?
    @State private var loadError: String?
    @State private var showImportPreview = false
    @State private var archiveData: Data?
    @State private var showDeleteConfirm = false

    var body: some View {
        Form {
            Section {
                Button {
                    initiateRestore()
                } label: {
                    Label(restoreLabel, systemImage: "clock.arrow.circlepath")
                }
                .disabled(books == nil)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete backup", systemImage: "trash")
                }
            } header: {
                Text(backup.name)
            } footer: {
                Text(restoreFooter)
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
                        // Enumerated identity: duplicate books in a backup
                        // (same title, distinct UUIDs) must each get a row —
                        // id alone would collapse equal ids, and duplicate
                        // titles would be fine either way with index-based
                        // identity as long as the list is static per load.
                        ForEach(Array(books.enumerated()), id: \.offset) { _, book in
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
                    sourceName: backup.name
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

    private var restoreLabel: String {
        if SharedLibraryMembershipGate.membership != .none {
            return "Restore this backup"
        }
        return "Restore this backup"
    }

    private var restoreFooter: String {
        if SharedLibraryMembershipGate.membership != .none {
            return "A shared library is active, so restoring stays on the shared mirror — your sync method doesn't change. Restoring offers the same choice as importing a file: add only books you don't have, or replace the whole library with this backup."
        }
        return "Restoring offers the same choice as importing a file: add only books you don't have, or replace the whole library with this backup."
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

    /// Restoring replaces the ACTIVE library's content on the CURRENT
    /// provider — backups are one synced set, so there is no per-provider
    /// origin to switch to anymore.
    private func initiateRestore() {
        guard archiveData != nil else { loadBooks(); return }
        showImportPreview = true
    }
}
