import SwiftUI
import SwiftData

/// Confirmation sheet for "Delete Library": lists what's removed, warns
/// about an active share, and offers a checkmark to keep or delete the
/// saved backups (kept by default).
struct DeleteLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let sharingActive: Bool
    let hasBackups: Bool
    let onConfirm: () -> Void

    @State private var keepBackups = true
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var exportFailed = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)

                Text("Delete Library?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    Text("This permanently deletes every book, note, reading list, and connection. Your member profile and settings stay. This cannot be undone.")
                    if sharingActive {
                        Label("This also stops sharing the library with everyone.", systemImage: "person.2.slash")
                            .foregroundStyle(.orange)
                    }
                    if hasBackups {
                        Toggle(isOn: $keepBackups) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep saved backups")
                                Text("Uncheck to also delete every backup of this library.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.callout)

                Button {
                    exportFirst()
                } label: {
                    HStack {
                        Label("Export a copy first", systemImage: "square.and.arrow.up")
                        Spacer()
                        if isExporting {
                            ProgressView()
                        }
                    }
                }
                .disabled(isExporting)
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Save or share export", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()

                Button(role: .destructive) {
                    onConfirm(keepBackups: keepBackups)
                    dismiss()
                } label: {
                    Text("Delete Library")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Delete Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't export", isPresented: $exportFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The library export failed. Nothing was deleted — you can try again or cancel.")
            }
        }
    }

    /// Writes the current library to a temp zip the user can share before
    /// anything is deleted. Reuses LibraryDataService.export (same format as
    /// Settings > Export library).
    private func exportFirst() {
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            guard let data = await LibraryDataService.export(context: Persistence.shared.mainContext) else {
                exportFailed = true
                return
            }
            let member = LibraryDataService.activeMemberName(Persistence.shared.mainContext)
            let filename = LibraryDataService.exportFileName(
                kind: "Library",
                libraryName: LibraryScope.shared.activeName(context: Persistence.shared.mainContext, memberName: member),
                memberName: member,
                ext: "zip"
            )
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: url)
                exportURL = url
            } catch {
                exportFailed = true
            }
        }
    }

    private func onConfirm(keepBackups: Bool) {
        if !keepBackups {
            BackupStore.deleteAll()
        }
        onConfirm()
    }
}
