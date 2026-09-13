import SwiftUI
import SwiftData

/// Advanced settings: diagnostics and destructive maintenance actions that
/// most users never need day-to-day. Reached from Settings → Advanced.
struct AdvancedSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openLibraryTab) private var openLibraryTab

    @State private var aiLogs: [AILogEntry] = []
    @State private var isDeleting = false
    @State private var lastError: String?
    @State private var showError = false
    @State private var showDeleteEverythingConfirm = false
    @State private var showDeleteTypeConfirm = false
    @State private var deleteConfirmText = ""

    var body: some View {
        Form {
            aiLogsSection
            startFreshSection
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadLogs() }
        .alert(
            "Delete everything and start fresh?",
            isPresented: $showDeleteEverythingConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                showDeleteTypeConfirm = true
            }
        } message: {
            Text("This permanently deletes every book, note, reading list, connection, and member — a full reset, as if the app had never been used. All backups are deleted too. Export a copy first if you want one. This cannot be undone." + (SharedLibraryMembershipGate.membership != .none ? " This also stops sharing the library with everyone." : ""))
        }
        .sheet(isPresented: $showDeleteTypeConfirm) {
            DeleteLibraryConfirmView(confirmText: $deleteConfirmText) {
                deleteAllData()
                showDeleteTypeConfirm = false
            }
            .presentationDetents([.medium])
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastError ?? "")
        }
    }

    // MARK: - Sections

    private var aiLogsSection: some View {
        Section {
            if aiLogs.isEmpty {
                Text("No AI activity logged yet. Ask a question or tap Test connection to see request logs here.")
            } else {
                ForEach(Array(aiLogs.prefix(30))) { entry in
                    logRow(entry)
                }
                Button("Clear logs", role: .destructive) {
                    AILogStore.clear()
                    reloadLogs()
                }
            }
        } header: {
            Text("AI connection logs")
        } footer: {
            Text("Shows the last 30 requests — endpoint, outcome, errors, and timing — so connection issues are visible. Logs stay on this device.")
        }
    }

    private var startFreshSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteEverythingConfirm = true
            } label: {
                Label("Delete everything and start fresh", systemImage: "arrow.counterclockwise")
            }
            .disabled(isDeleting)
        } footer: {
            Text("Removes every book, note, reading list, connection, and your member profile — the app returns to its first-launch state. Export a backup first if you want to keep anything.")
        }
    }

    // MARK: - Logs

    @MainActor
    private func reloadLogs() {
        // Newest first — the most recent request is what a user checking logs
        // actually cares about; it goes at the top rather than off-screen.
        aiLogs = AILogStore.entries().reversed()
    }

    private func logRow(_ entry: AILogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.logIcon(for: entry.kind))
                .foregroundStyle(Self.logColor(for: entry.kind))
                .font(.caption)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.detail)
                    .font(.caption)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                    Text("·")
                    Text(entry.engine.displayName)
                    if let latency = entry.latencyText {
                        Text("·")
                        Text(latency)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private static func logIcon(for kind: AILogEntry.Kind) -> String {
        switch kind {
        case .attempt: return "arrow.up.circle"
        case .success: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private static func logColor(for kind: AILogEntry.Kind) -> Color {
        switch kind {
        case .attempt: return .secondary
        case .success: return .green
        case .error: return .red
        }
    }

    // MARK: - Delete everything

    /// "Delete everything and start fresh": a full factory reset — every
    /// record including the member identity, so the user is returned to the
    /// login screen as if the app had never been used.
    /// A provider switch copies the library between the local
    /// (default.store) and iCloud (default-cloud.store) stores via merge —
    /// so after any switch, BOTH stores hold the books. Deleting only the
    /// live store would leave a full copy in the other one, resurfacing on
    /// the next switch. This clears whichever store is NOT currently live.
    private func clearNonLiveStore(liveProvider: LibrarySync, contentOnly: Bool) {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
                Library.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let otherProvider: LibrarySync = liveProvider == .iCloud ? .localOnly : .iCloud
        let container = SyncStoreRegistry.makeContainer(for: otherProvider)
        if contentOnly {
            LibraryDataService.deleteLibraryContent(context: ModelContext(container))
        } else {
            LibraryDataService.deleteAll(context: ModelContext(container))
        }
    }

    private func deleteAllData() {
        isDeleting = true
        SyncSettings.markBulkChange()
        // Clear the LIVE store first: the UI and RootView's login switch
        // read from Persistence.shared, so the user sees the empty state
        // (login screen) immediately, without a restart.
        LibraryDataService.deleteAll(context: modelContext)
        clearNonLiveStore(liveProvider: SyncSettings.selectedProvider, contentOnly: false)
        // A full reset wipes EVERYTHING, backups included — all three
        // backup folders (live + parked companions).
        BackupStore.deleteAll()
        // A full reset behaves like a brand-new install: the provider
        // choice returns to the default (.iCloud) on next launch.
        SyncSettings.resetProvider()
        wipeAIRemnantsAndSearchHistory()
        // While sharing, delete-all also ENDS the share (owner: zone and
        // share removed, participants lose access; participant: leaves the
        // share). Then clear the destination private store so no copy
        // survives there either; discardSharedContent removes the mirror
        // store file.
        if SharedLibraryMembershipGate.membership != .none {
            Task { @MainActor in
                do {
                    try await SharedLibraryCoordinator.discardSharedContent()
                    let context = try SharedLibraryCoordinator.privateContextAfterDiscard()
                    LibraryDataService.deleteAll(context: context)
                } catch {
                    lastError = error.localizedDescription
                    showError = true
                }
                isDeleting = false
            }
        } else {
            isDeleting = false
        }
    }

    /// Removes AI remnants and search history so "the entire library is
    /// deleted" is literally true: the Ask AI conversation transcript file
    /// (`ai-conversation.json`), the AI connection request logs, and the
    /// add-book search history.
    private func wipeAIRemnantsAndSearchHistory() {
        AILogStore.clear()
        LocalTranscriptMemory().clear()
        UserDefaults.standard.removeObject(forKey: "searchHistory")
    }
}
struct DeleteLibraryConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var confirmText: String
    let onDelete: () -> Void
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var exportFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.red)
                Text("Delete ALL data?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("This permanently erases every book, note, reading list, connection, member, and backup from this device. There is no undo. To confirm, type DELETE below, then tap the red button.")
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
            .alert("Couldn't export", isPresented: $exportFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The library export failed. Nothing was deleted — you can try again or cancel.")
            }
        }
    }

    /// Writes the current library to a temp zip the user can share before
    /// the full wipe. Same export format as Settings > Export library.
    private func exportFirst() {
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            guard let data = await LibraryDataService.export(context: Persistence.shared.mainContext) else {
                exportFailed = true
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "LibraryCove-Library-\(formatter.string(from: Date())).zip"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: url)
                exportURL = url
            } catch {
                exportFailed = true
            }
        }
    }
}
