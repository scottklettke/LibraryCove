import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings screen: profile, library data (export/import/delete), sync and AI.
struct SettingsView: View {
    let user: User
    @Environment(\.modelContext) private var modelContext

    // Export
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var showExportShare = false

    // Import
    @State private var showFileImporter = false
    @State private var pendingImportData: Data?
    @State private var previewSummary: ImportSummary?
    @State private var showImportPreview = false
    @State private var showReplaceConfirm = false
    @State private var showMergeList = false
    @State private var mergeCandidates: [BookDTO] = []
    @State private var isImporting = false

    // Delete
    @State private var showDeleteConfirm = false
    @State private var showDeleteTypeConfirm = false
    @State private var deleteConfirmText = ""
    @State private var isDeleting = false

    @FocusState private var nameFieldFocused: Bool

    // Feedback
    @State private var lastResult: String?
    @State private var showResult = false
    @State private var lastError: String?
    @State private var showError = false

    private var zipType: UTType {
        UTType(filenameExtension: "zip") ?? .data
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Library name",
                                  text: Binding(get: { user.displayName },
                                                set: { user.displayName = $0 }))
                            .focused($nameFieldFocused)
                        Button {
                            nameFieldFocused = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit library name")
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Tap the pencil to edit the name used for “Added by” on your books.")
                }

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

                    Button {
                        showFileImporter = true
                    } label: {
                        HStack {
                            Label("Import library", systemImage: "tray.and.arrow.down")
                            Spacer()
                            if isImporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isImporting)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete all data", systemImage: "trash")
                    }
                    .disabled(isDeleting)
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export saves your whole library as a zipped, readable file you can review and edit. Import restores from such a file by replacing the current library. Delete permanently removes everything — export first to keep a backup.")
                }

                Section("Sync") {
                    LabeledContent("Provider", value: "iCloud / CloudKit (planned)")
                    LabeledContent("Status", value: "Local-only")
                }

                Section("AI") {
                    LabeledContent("Inference", value: "Local model or endpoint")
                }
            }
            .navigationTitle("Settings")
            .alert(
                "Delete all data?",
                isPresented: $showDeleteConfirm
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) {
                    showDeleteTypeConfirm = true
                }
            } message: {
                Text("This permanently deletes every book, note, reading list, connection, and member. This cannot be undone.")
            }
            .sheet(isPresented: $showDeleteTypeConfirm) {
                DeleteLibraryConfirmView(confirmText: $deleteConfirmText) {
                    deleteAllData()
                    showDeleteTypeConfirm = false
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showExportShare) {
                exportShareSheet
            }
            .sheet(isPresented: $showImportPreview) {
                importPreviewSheet
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [zipType]) { result in
                handleFilePicker(result)
            }
            .alert("Import complete", isPresented: $showResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(lastResult ?? "")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(lastError ?? "Something went wrong.")
            }
        }
    }

    // MARK: - Export share sheet

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

    // MARK: - Import preview sheet

    private var importPreviewSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("How do you want to import?")
                    .font(.headline)
                Text("This file contains:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(previewSummary?.formatted ?? "No items.")
                    .font(.callout.bold())

                Button {
                    presentMergeList()
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
            .padding()
            .navigationTitle("Import library")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showMergeList) {
                mergeListContent
            }
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
                Text(self.replaceWarning)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showImportPreview = false }
                }
            }
        }
    }

    private var replaceWarning: String {
        let current = (try? modelContext.fetchCount(FetchDescriptor<Book>())) ?? 0
        let incoming = previewSummary?.books ?? 0
        return "This removes \(current) book\(current == 1 ? "" : "s") (with their notes and lists) "
            + "and imports \(incoming) book\(incoming == 1 ? "" : "s") from the file instead. "
            + "This cannot be undone."
    }

    // MARK: - Merge list (pushed inside the import preview sheet)

    private var mergeListContent: some View {
        Group {
            if mergeCandidates.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("Nothing new to import")
                        .font(.headline)
                    Text("Every book in the file is already in your library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(mergeCandidates, id: \.id) { book in
                            LabeledContent {
                                Text(book.authors.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            } label: {
                                Text(book.title)
                                    .font(.body)
                            }
                        }
                    } footer: {
                        Text("Books already in your library are skipped.")
                    }
                }
            }
        }
        .navigationTitle("Books to import (\(mergeCandidates.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    showMergeList = false
                    mergeCandidates = []
                }
            }
            if !mergeCandidates.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(mergeCandidates.count)") {
                        performMergeImport()
                    }
                    .disabled(isImporting)
                }
            }
        }
    }

    // MARK: - Actions

    private func exportLibrary() {
        isExporting = true
        Task { @MainActor in
            let data = await LibraryDataService.export(context: modelContext)
            isExporting = false
            guard let data else {
                lastError = LibraryDataError.exportFailed.errorDescription
                showError = true
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "BookNexus-Library-\(formatter.string(from: Date())).zip"
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
        // after the security scope closes, then preview (no writes yet).
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            let data = try Data(contentsOf: tempURL)
            let summary = try LibraryDataService.previewArchive(data: data)
            try FileManager.default.removeItem(at: tempURL)
            pendingImportData = data
            previewSummary = summary
            showImportPreview = true
        } catch {
            lastError = (error as? LibraryDataError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            showError = true
        }
    }

    private func performReplaceImport() {
        guard let pendingImportData else { return }
        isImporting = true
        Task { @MainActor in
            do {
                let summary = try LibraryDataService.importArchive(data: pendingImportData, context: modelContext)
                finishImport(summary, note: nil)
            } catch {
                finishImport(nil, note: error.localizedDescription)
            }
        }
    }

    private func presentMergeList() {
        guard let pendingImportData else { return }
        do {
            mergeCandidates = try LibraryDataService.mergeCandidates(data: pendingImportData, context: modelContext)
            showMergeList = true
        } catch {
            lastError = (error as? LibraryDataError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            showError = true
        }
    }

    private func performMergeImport() {
        guard let pendingImportData else { return }
        isImporting = true
        Task { @MainActor in
            do {
                let added = try LibraryDataService.mergeArchive(data: pendingImportData, context: modelContext)
                showMergeList = false
                mergeCandidates = []
                let skipped = (previewSummary?.books ?? 0) - added.books
                finishImport(added, note: skipped > 0 ? " Skipped \(skipped) already in your library." : nil)
            } catch {
                finishImport(nil, note: error.localizedDescription)
            }
        }
    }

    private func finishImport(_ summary: ImportSummary?, note: String?) {
        isImporting = false
        if let summary {
            pendingImportData = nil
            previewSummary = nil
            showImportPreview = false
            showReplaceConfirm = false
            lastResult = "Imported \(summary.formatted)." + (note ?? "")
            showResult = true
        } else {
            lastError = note ?? "Something went wrong."
            showError = true
        }
    }

    private func deleteAllData() {
        isDeleting = true
        LibraryDataService.deleteAll(context: modelContext)
        isDeleting = false
        // The active member is gone, so RootView switches to the login screen —
        // a truly fresh start.
    }
}

/// Second layer of the delete guard: requires typing DELETE to enable the
/// destructive button.
private struct DeleteLibraryConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var confirmText: String
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.red)
                Text("Delete ALL data?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("This permanently erases every book, note, reading list, connection, and member from this device. There is no undo. To confirm, type DELETE below, then tap the red button.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TextField("Type DELETE", text: $confirmText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Text("Permanently delete and start fresh")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .disabled(confirmText != "DELETE")
                Button(role: .cancel) {
                    dismiss()
                    confirmText = ""
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
        }
    }
}
