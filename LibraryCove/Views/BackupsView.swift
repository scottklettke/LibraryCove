import SwiftUI
import SwiftData

/// Backup manager: create a backup of the current library state, browse
/// existing backups (name by date + book count, size), and delete them
/// individually.
struct BackupsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openLibraryTab) private var openLibraryTab

    @State private var backups: [BackupStore.Item] = []
    @State private var isBackingUp = false
    @State private var lastResult: String?
    @State private var showResult = false
    @State private var lastError: String?
    @State private var showError = false
    /// Backup pending deletion (drives the confirm dialog).
    @State private var backupToDelete: BackupStore.Item?

    var body: some View {
        Form {
            Section {
                Button {
                    createBackup()
                } label: {
                    HStack {
                        Label("Back up library now", systemImage: "externaldrive.badge.plus")
                        Spacer()
                        if isBackingUp {
                            ProgressView()
                        }
                    }
                }
                .disabled(isBackingUp)
            } header: {
                Text("Backup")
            } footer: {
                Text("Saves a zip of your whole library (books, notes, reading lists, covers) under its date and book count. Backups stay on this device and follow the library when you switch between Local only and iCloud Sync.")
            }

            Section {
                if backups.isEmpty {
                    Text("No backups yet. Create one above — it's a good idea before deleting the library or importing.")
                } else {
                    ForEach(backups) { backup in
                        Button {
                            backupToDelete = backup
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backup.name)
                                        .font(.body)
                                        .lineLimit(2)
                                    Text(backup.sizeText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            } header: {
                Text("Existing backups (\(backups.count))")
            }
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .alert("Import complete", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastResult ?? "")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastError ?? "")
        }
        .confirmationDialog(
            "Delete this backup?",
            isPresented: Binding(
                get: { backupToDelete != nil },
                set: { if !$0 { backupToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete backup", role: .destructive) {
                if let backup = backupToDelete {
                    BackupStore.delete(url: backup.url)
                    reload()
                }
                backupToDelete = nil
            }
            Button("Cancel", role: .cancel) { backupToDelete = nil }
        } message: {
            if let name = backupToDelete?.name {
                Text("“\(name)” will be deleted. This cannot be undone.")
            }
        }
    }

    private func reload() {
        backups = BackupStore.list()
    }

    private func createBackup() {
        isBackingUp = true
        Task { @MainActor in
            defer { isBackingUp = false }
            guard let data = await LibraryDataService.export(context: modelContext) else {
                lastError = LibraryDataError.exportFailed.errorDescription
                showError = true
                return
            }
            let count = (try? modelContext.fetchCount(FetchDescriptor<Book>())) ?? 0
            do {
                let name = try BackupStore.save(data: data, bookCount: count)
                lastResult = "Backup “\(name)” created."
                showResult = true
            } catch {
                lastError = error.localizedDescription
                showError = true
            }
            reload()
        }
    }
}
