import SwiftUI
import SwiftData

/// Detail page for one backup: lists every book it contains (newest added
/// first) and offers to restore it — with the same add-new-only /
/// replace-whole-library choice as a zip-file import. Restoring a backup
/// that was made under the other provider also switches the sync method to
/// that provider (silently), unless a shared library is active — shares
/// never switch silently.
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
    @State private var isRestoring = false
    @State private var showDeleteConfirm = false
    /// Set when the pre-restore provider switch was deferred (iCloud still
    /// converging after a bulk change) — surfaced so the restore doesn't
    /// silently land on a different provider than the button promised.
    @State private var switchDeferredMessage: String?

    var body: some View {
        Form {
            Section {
                Button {
                    initiateRestore()
                } label: {
                    HStack {
                        Label(restoreLabel, systemImage: "clock.arrow.circlepath")
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
                    // The provider switch (if any) already happened before
                    // the sheet opened — see initiateRestore.
                    onRestored()
                    openLibraryTab()
                }
            }
        }
        .alert("Switch deferred", isPresented: Binding(
            get: { switchDeferredMessage != nil },
            set: { if !$0 { switchDeferredMessage = nil } }
        )) {
            Button("Continue", role: .cancel) {}
        } message: {
            Text(switchDeferredMessage ?? "")
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

    /// True when this backup belongs to the OTHER provider's set and the
    /// app isn't sharing — restoring it should switch the sync method back.
    private var shouldSwitchOnRestore: Bool {
        backup.origin != SyncSettings.selectedProvider
            && backup.origin.isAvailableNow
            && SharedLibraryMembershipGate.membership == .none
    }

    private var restoreLabel: String {
        if SharedLibraryMembershipGate.membership != .none {
            return "Restore this backup"
        }
        return shouldSwitchOnRestore
            ? "Restore & switch to \(backup.origin.displayName)"
            : "Restore this backup"
    }

    private var restoreFooter: String {
        if SharedLibraryMembershipGate.membership != .none {
            return "A shared library is active, so restoring stays on the shared mirror — your sync method doesn't change. Restoring offers the same choice as importing a file: add only books you don't have, or replace the whole library with this backup."
        }
        if shouldSwitchOnRestore {
            return "This backup was made under \(backup.origin.displayName). Restoring it switches your sync method to \(backup.origin.displayName) first — the current library moves there — and then replaces it with this backup's contents."
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

    /// Restoring a backup from the other provider switches the sync method
    /// to that provider FIRST (silently), so the backup's contents replace
    /// into the store the user will actually be on. Switching after the
    /// restore would instead merge the restored library into the other
    /// store's stale set — old books would resurface.
    private func initiateRestore() {
        guard archiveData != nil else { loadBooks(); return }
        guard shouldSwitchOnRestore else {
            showImportPreview = true
            return
        }
        isRestoring = true
        Task { @MainActor in
            do {
                try await ProviderSwitcher.perform(to: backup.origin)
            } catch let error as LibrarySyncError where error == .iCloudStillSyncing {
                // The switch was refused (iCloud still converging after a
                // bulk change). Restore anyway on the current provider, but
                // SAY so — the button promised a switch.
                switchDeferredMessage = "iCloud is still syncing a recent change, so your sync method wasn't switched — the restore will land on \(SyncSettings.selectedProvider.displayName). Retry in a couple of minutes, or switch via Settings > Sync afterwards."
            } catch {
                switchDeferredMessage = "The switch to \(backup.origin.displayName) failed (\(error.localizedDescription)). The restore will land on \(SyncSettings.selectedProvider.displayName)."
            }
            isRestoring = false
            showImportPreview = true
        }
    }
}
