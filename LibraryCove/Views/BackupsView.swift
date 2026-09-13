import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Backup + data hub: create a backup of the current library state, export
/// the library as a shareable zip, import from a zip file, browse existing
/// backups (name by date + book count, size), and restore from a backup.
struct BackupsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openLibraryTab) private var openLibraryTab

    @State private var backups: [BackupStore.Item] = []
    @State private var isBackingUp = false
    @State private var lastResult: String?
    @State private var showResult = false
    /// True when `lastResult` reports a created backup (vs. an import),
    /// so the alert title says "Backup complete" instead of "Import complete".
    @State private var resultIsBackup = false
    @State private var lastError: String?
    @State private var showError = false
    /// Backup pending deletion (drives the confirm dialog).
    @State private var backupToDelete: BackupStore.Item?
    // Export (share a zip of the current library).
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showExportShare = false
    // Import from a zip file (same flow as the old Settings > Import library).
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var pendingImportData: Data?
    @State private var pendingImportName: String?

    private var zipType: UTType {
        UTType(filenameExtension: "zip") ?? .data
    }

    var body: some View {
        Form {
            backupSection
            zipTransferSection
            backupListSection
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [zipType]) { result in
            handleFilePicker(result)
        }
        .sheet(isPresented: $showExportShare) {
            exportShareSheet
        }
        .sheet(item: Binding(
            get: { pendingImportData.map { ImportPayload(data: $0, name: pendingImportName ?? "file") } },
            set: { payload in
                if payload == nil { pendingImportData = nil; pendingImportName = nil }
            }
        )) { payload in
            ImportPreviewView(
                archiveData: payload.data,
                sourceName: payload.name
            ) { message in
                resultIsBackup = false
                lastResult = message
                showResult = true
                reload()
                openLibraryTab()
            }
        }
        .alert(resultIsBackup ? "Backup complete" : "Import complete", isPresented: $showResult) {
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

    // MARK: - Sections

    private var backupSection: some View {
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
    }

    private var zipTransferSection: some View {
        Section {
            Button {
                exportLibrary()
            } label: {
                HStack {
                    Label("Export library", systemImage: "square.and.arrow.up")
                    Spacer()
                    if isExporting {
                        ProgressView()
                    }
                }
            }
            .disabled(isExporting)

            Menu {
                Button {
                    showFileImporter = true
                } label: {
                    Label("From a zip file", systemImage: "doc.zipper")
                }
                Button {
                    // The saved-backup list is on this page below; scrolling
                    // hint lives in the footer.
                } label: {
                    Label("From a saved backup (below)", systemImage: "clock.arrow.circlepath")
                }
            } label: {
                HStack {
                    Label("Import library", systemImage: "tray.and.arrow.down")
                    Spacer()
                    if isImporting {
                        ProgressView()
                    }
                }
            }
        } header: {
            Text("Export & Import")
        } footer: {
            Text("Export saves your whole library as a zipped, readable file you can save, share, or edit. Import restores from such a file — you choose to add only its new books or replace the whole library. The same choice is offered when restoring a backup. Restoring from a saved backup: pick one from the list below and tap Restore.")
        }
    }

    private var backupListSection: some View {
        Section {
            if backups.isEmpty {
                Text("No backups yet. Create one above — it's a good idea before deleting the library or importing.")
            } else {
                ForEach(backups) { backup in
                    NavigationLink {
                        BackupDetailView(backup: backup) {
                            reload()
                        }
                    } label: {
                        backupRowLabel(backup)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            backupToDelete = backup
                        } label: {
                            Label("Delete backup", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Existing backups (\(backups.count))")
        }
    }

    /// Inline provider tag after a backup's name — the user's wording:
    /// "(Local)" rather than the picker's "Local only".
    private func originTag(_ origin: LibrarySync) -> String {
        origin == .localOnly ? "Local" : origin.displayName
    }

    private func backupRowLabel(_ backup: BackupStore.Item) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(backup.name) (\(originTag(backup.origin)))")
                    .font(.body)
                    .lineLimit(2)
                Text(backup.sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportShareSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                Text("Library export ready")
                    .font(.headline)
                Text("The file contains library.json, cover images, and README-FORMAT.md inside a zip you can save, review, and edit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let exportURL {
                    // Sharing a file:// URL hands the zip to the share sheet
                    // (Save to Files, Mail, AirDrop…), keeping its filename.
                    ShareLink(item: exportURL) {
                        Label("Save or share export", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Export library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showExportShare = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        backups = BackupStore.listAll()
    }

    private func createBackup() {
        isBackingUp = true
        Task { @MainActor in
            defer { isBackingUp = false }
            // Resolve the live store at execution time: a restore-with-switch
            // hot-swaps the container mid-session, and a captured environment
            // context would then point at the outgoing store.
            let liveContext = Persistence.shared.mainContext
            guard let data = await LibraryDataService.export(context: liveContext) else {
                lastError = LibraryDataError.exportFailed.errorDescription
                showError = true
                return
            }
            let count = (try? liveContext.fetchCount(LibraryScope.activeBooksDescriptor(context: liveContext))) ?? 0
            do {
                let name = try BackupStore.save(data: data, bookCount: count)
                resultIsBackup = true
                lastResult = "Backup “\(name)” created."
                showResult = true
            } catch {
                lastError = error.localizedDescription
                showError = true
            }
            reload()
        }
    }

    private func exportLibrary() {
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            guard let data = await LibraryDataService.export(context: Persistence.shared.mainContext) else {
                lastError = LibraryDataError.exportFailed.errorDescription
                showError = true
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "LibraryCove-Library-\(formatter.string(from: Date())).zip"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: url)
                exportURL = url
                showExportShare = true
            } catch {
                lastError = error.localizedDescription
                showError = true
            }
        }
    }

    private func handleFilePicker(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Copy into a private temporary location so the bytes stay readable
        // after the security scope closes, then validate before previewing
        // (no writes yet).
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            let data = try Data(contentsOf: tempURL)
            _ = try LibraryDataService.previewArchive(data: data)
            try FileManager.default.removeItem(at: tempURL)
            pendingImportName = url.lastPathComponent
            pendingImportData = data
        } catch {
            lastError = (error as? LibraryDataError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            showError = true
        }
    }
}

/// Identifies the archive feeding the import preview sheet (`Identifiable`
/// so `.sheet(item:)` can present it from optional data).
private struct ImportPayload: Identifiable {
    let data: Data
    let name: String
    var id: String { name + String(data.hashValue) }
}

import SwiftData

/// Preview + execution of an import from an archive (zip file or backup).
/// Offers the same two choices the old Settings > Import library did:
/// add only new books (merge, duplicates skipped) or replace the whole
/// library. Replace preserves the active member's profile name and tears
/// down an active share first.
struct ImportPreviewView: View {
    let archiveData: Data
    let sourceName: String
    /// Called after a successful import so the presenter can refresh.
    var onImported: (_ message: String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var summary: ImportSummary?
    @State private var loadError: String?
    @State private var showReplaceConfirm = false
    @State private var isImporting = false
    /// Name of the library the import lands in. Defaults to the active
    /// library's name; changing it creates/uses a library with that name.
    @State private var targetLibraryName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("How do you want to import?")
                    .font(.headline)
                Text("From “\(sourceName)” — this file contains:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(summary?.formatted ?? "No items.")
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Import into library")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Library name", text: $targetLibraryName)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 24)
                }

                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    Button {
                        performMergeImport()
                    } label: {
                        Label("Add new books only", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)

                    Button {
                        showReplaceConfirm = true
                    } label: {
                        Text("Replace library with this file")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(isImporting)
                }

                if isImporting {
                    ProgressView()
                }
            }
            .padding()
            .navigationTitle("Import library")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Replace your library?",
                isPresented: $showReplaceConfirm,
                titleVisibility: .visible
            ) {
                Button("Replace and import", role: .destructive) {
                    performReplaceImport()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(replaceWarning)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // A replace import tears down the active share and wipes the
            // library — swiping the sheet away mid-run must not be possible.
            .interactiveDismissDisabled(isImporting)
            .task {
                targetLibraryName = LibraryScope.activeName(
                    context: Persistence.shared.mainContext,
                    memberName: ((try? Persistence.shared.mainContext.fetch(FetchDescriptor<User>(
                        predicate: #Predicate { $0.isActive }
                    ))) ?? []).first?.displayName ?? "")
                loadPreview()
            }
        }
    }

    private var replaceWarning: String {
        let incoming = summary?.books ?? 0
        return "This deletes every book, note, reading list, and connection currently in your library, then imports \(incoming) book\(incoming == 1 ? "" : "s") from the file. Your member profile stays. This cannot be undone."
    }

    private func loadPreview() {
        do {
            summary = try LibraryDataService.previewArchive(data: archiveData)
        } catch {
            loadError = (error as? LibraryDataError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func finishImport(_ imported: ImportSummary?, note: String?) {
        isImporting = false
        if let imported {
            SyncSettings.markBulkChange()
            onImported(importMessage(for: imported, note: note))
            dismiss()
        } else if let note {
            loadError = note
        }
    }

    /// Human-readable outcome: what was imported, plus skipped-duplicates
    /// note for merges.
    private func importMessage(for imported: ImportSummary, note: String?) -> String {
        "Imported \(imported.formatted)." + (note ?? "")
    }

    /// Ensures a library named `targetLibraryName` exists and is active, so
    /// the import stamps its rows into the chosen library.
    private func prepareTargetLibrary() {
        let context = Persistence.shared.mainContext
        let requested = targetLibraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return }
        let current = LibraryScope.activeName(
            context: context,
            memberName: ((try? context.fetch(FetchDescriptor<User>(
                predicate: #Predicate { $0.isActive }
            ))) ?? []).first?.displayName ?? "")
        guard requested != current else { return }
        // An existing library with this name? Activate it. Otherwise create.
        if let existing = LibraryScope.all(context: context).first(where: {
            $0.name.compare(requested, options: .caseInsensitive) == .orderedSame
        }) {
            LibraryScope.activate(existing, context: context)
        } else {
            _ = try? LibraryScope.create(name: requested, makeActive: true, context: context)
        }
    }

    private func performMergeImport() {
        isImporting = true
        Task { @MainActor in
            prepareTargetLibrary()
            do {
                // Resolve the live store at execution time: a restore can
                // switch providers before importing, and the injected
                // environment context would then point at the old store.
                let added = try LibraryDataService.mergeArchive(data: archiveData, context: Persistence.shared.mainContext)
                let skipped = (summary?.books ?? 0) - added.books
                let note: String? = skipped > 0 ? " Skipped \(skipped) already in your library." : nil
                finishImport(added, note: note)
            } catch {
                finishImport(nil, note: error.localizedDescription)
            }
        }
    }

    private func performReplaceImport() {
        isImporting = true
        Task { @MainActor in
            prepareTargetLibrary()
            do {
                // A replace import while sharing ends the share: the
                // imported content is the user's new private library, not a
                // continuation of the share. Mirror content is deliberately
                // discarded, so the import runs on the private store.
                let context: ModelContext
                if SharedLibraryMembershipGate.membership != .none {
                    try await SharedLibraryCoordinator.discardSharedContent()
                    context = try SharedLibraryCoordinator.privateContextAfterDiscard()
                } else {
                    context = Persistence.shared.mainContext
                }
                // The user's chosen profile name survives a replace import:
                // capture it, import (the archive's own members are
                // installed, including its identity), then re-apply the
                // name to every member row so the greeting/profile stays
                // the user's.
                let activeUser = ((try? context.fetch(FetchDescriptor<User>(
                    predicate: #Predicate { $0.isActive }
                ))) ?? []).first
                let chosenName = activeUser?.displayName
                let imported = try LibraryDataService.importArchive(data: archiveData, context: context)
                let members = (try? context.fetch(FetchDescriptor<User>())) ?? []
                if let chosenName {
                    for member in members where member.displayName != chosenName {
                        member.displayName = chosenName
                    }
                }
                if !members.isEmpty { try? context.save() }
                finishImport(imported, note: nil)
            } catch {
                finishImport(nil, note: error.localizedDescription)
            }
        }
    }
}
