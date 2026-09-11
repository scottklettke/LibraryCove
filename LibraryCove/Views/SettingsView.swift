import CloudKit
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

    // Sync
    @State private var syncProvider: LibrarySync = SyncSettings.selectedProvider
    @State private var isSwitchingSync = false
    @State private var showSyncRestartNotice = false

    // Shared library
    @State private var isPreparingShare = false
    @State private var sharedMembers: [SharedLibraryMember] = []
    @State private var showSharingSheet = false
    @State private var shareSheetShare: CKShare?
    @State private var showStopSharingConfirm = false
    @State private var showLeaveConfirm = false
    @State private var keepCopyOnLeave = true

    // AI
    @State private var aiEngine: AIEngine = AIConfig.selectedEngine
    @State private var aiBaseURL: String = AIConfig.openAIBaseURL
    @State private var aiAPIKey: String = AIConfig.openAIAPIKey
    @State private var availableModelInfos: [AIModelInfo] = []
    @State private var modelListNote: String?
    @State private var aiAvailability: AIAvailability?
    @State private var aiModel: String = AIConfig.openAIModel
    @State private var contextWindow: Int = AIConfig.maxContextTokens
    @State private var aiLogs: [AILogEntry] = []
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testResultIsError = false

    // Description lookup
    @State private var searchEngine: WebSearchEngine = WebSearchEngine.selected

    // Feedback
    @State private var lastResult: String?
    @State private var showResult = false
    @State private var lastError: String?
    @State private var showError = false

    private var zipType: UTType {
        UTType(filenameExtension: "zip") ?? .data
    }

    /// Changes whenever any AI setting shifts, so the status re-checks
    /// after edits (engine, base URL, or key). Includes only the key's
    /// length/hash — never the key itself.
    private var aiConfigSignature: String {
        "\(aiEngine.rawValue)|\(aiBaseURL)|\(aiAPIKey.count)-\(aiAPIKey.hashValue)"
    }

    private var aiStatusText: String {
        switch aiAvailability {
        case nil:
            return "Checking…"
        case .available:
            return "Ready to use"
        case .unavailable(let reason):
            return reason
        }
    }

    private var aiStatusColor: Color {
        switch aiAvailability {
        case .available:
            return .green
        case nil, .unavailable:
            return .secondary
        }
    }

    /// Keyless web-grounding toggle (Settings → AI), backed by AIConfig.
    private var webSearchBinding: Binding<Bool> {
        Binding(get: { AIConfig.webSearchEnabled },
                set: { AIConfig.webSearchEnabled = $0 })
    }

    private var trimmedBaseURL: String {
        aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Model picker always lists a pinned value (so it stays visible after
    /// an override is chosen) plus every id the server reported. Keeps the
    /// value persistent and selectable even if the server list changes.
    private var modelPickerOptions: [String] {
        let override = AIConfig.openAIModel
        let ids = availableModelInfos.map(\.id)
        guard !override.isEmpty else { return ids }
        return [override] + ids.filter { $0 != override }
    }

    /// The auto-selected chat model the app would send right now, when the
    /// server reported ids and no override is pinned.
    private var autoChatModel: String? {
        OpenAICompatibleProvider.chooseChatModel(from: availableModelInfos.map(\.id))
    }

    /// Label for a model row: the server-provided display name when one
    /// exists, else the raw id (the value actually sent on the wire).
    private func pickerLabel(for id: String) -> String {
        guard let info = availableModelInfos.first(where: { $0.id == id }),
              let name = info.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return id }
        return name
    }

    /// A user-facing note when the server declared a context window for the
    /// model the app would actually use (pinned, or auto-selected). Requests
    /// are then sized to that window; the manual picker below only governs
    /// servers that don't report one.
    private var detectedContextNote: String? {
        let ids = availableModelInfos.map(\.id)
        let inUse = AIConfig.openAIModel.isEmpty
            ? OpenAICompatibleProvider.chooseChatModel(from: ids)
            : AIConfig.openAIModel
        guard let inUse,
              let info = availableModelInfos.first(where: { $0.id == inUse }),
              let declared = info.contextLength,
              declared >= AIConfig.minContextTokens else {
            return nil
        }
        let tokens = min(declared, AIConfig.maxContextTokensCeiling)
        return "Using the \(tokens / 1024)K context window the server reports for \(pickerLabel(for: inUse)). The setting below is only a fallback when a server doesn't declare one."
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

                Section {
                    Picker("Sync provider", selection: $syncProvider) {
                        // .sharedLibrary is entered only through the Share
                        // Library / join flows — the snapshot-pour switch
                        // would seed a share-less mirror with private data.
                        ForEach(LibrarySync.allCases.filter { $0 != .sharedLibrary }) { provider in
                            Text(provider.isAvailableNow
                                 ? provider.displayName
                                 : "\(provider.displayName) (coming soon)")
                                .tag(provider)
                        }
                    }
                    .disabled(isSwitchingSync)
                    LabeledContent("Status", value: syncStatusText(syncProvider))
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Local only keeps everything on this device. iCloud Sync stores your library in your private iCloud database and keeps devices in sync. Dropbox, Box, and Nextcloud are coming soon.")
                }

                sharedLibrarySection

                Section {
                    Picker("Engine", selection: $aiEngine) {
                        ForEach(AIEngine.allCases) { engine in
                            Text(engine.isAvailableNow
                                 ? engine.displayName
                                 : "\(engine.displayName) (coming soon)")
                                .tag(engine)
                        }
                    }
                    Toggle("Ground answers with web search", isOn: webSearchBinding)
                    LabeledContent("Status") {
                        Text(aiStatusText)
                            .foregroundStyle(aiStatusColor)
                    }
                    if aiEngine == .openAI {
                        TextField("Endpoint URL", text: $aiBaseURL, prompt: Text("http://localhost:11434/v1"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .accessibilityIdentifier("aiEndpointField")
                        Picker("Model", selection: $aiModel) {
                            Text("Auto (detect from server)").tag("")
                            ForEach(modelPickerOptions, id: \.self) { id in
                                Text(pickerLabel(for: id)).tag(id)
                            }
                        }
                        .accessibilityIdentifier("aiModelPicker")
                        // Since the server decides the model, show what the
                        // app would send right now instead of hiding it.
                        if AIConfig.openAIModel.isEmpty {
                            if let note = modelListNote {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let auto = autoChatModel {
                                Text("Will use \(auto) — discovered from this server.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Will ask the server which model it runs.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Saved") {
                            Text("Automatically as you type")
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await testConnection() }
                        } label: {
                            Label(isTesting ? "Testing…" : "Test connection",
                                  systemImage: isTesting ? "arrow.triangle.2.circlepath" : "bolt.fill")
                        }
                        .disabled(isTesting || trimmedBaseURL.isEmpty)
                        if let testResult {
                            LabeledContent(testResultIsError ? "Test failed" : "Test result") {
                                Text(testResult)
                                    .font(.caption)
                                    .foregroundStyle(testResultIsError ? Color.red : Color.green)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    Toggle("Show tokens/second", isOn: Binding(
                        get: { AIConfig.showTokenRate },
                        set: { AIConfig.showTokenRate = $0 }
                    ))
                    Picker("Context window", selection: $contextWindow) {
                        let options = [2048, 4096, 8192, 16384, 32768, 65536]
                        let present: [Int] = options.contains(AIConfig.maxContextTokens)
                            ? options
                            : (options + [AIConfig.maxContextTokens]).sorted()
                        ForEach(present, id: \.self) { tokens in
                            Text("\(tokens / 1024)K tokens").tag(tokens)
                        }
                    }
                    if let note = detectedContextNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text("Multi-model gateways like OpenRouter report each model's context, so the app sizes requests to the real window automatically once the model list loads. For servers that don't declare a window, set the context window below to match your model's limit — a larger window lets the AI search more of your library. Ground answers with web search is keyless: Ask AI looks up a Wikipedia article and DuckDuckGo results and cites their URLs; it adds a short fetch per question when enabled and stays off unless you turn it on.")
                }

                Section {
                    Picker("Search engine", selection: $searchEngine) {
                        ForEach(WebSearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .accessibilityIdentifier("searchEnginePicker")
                } header: {
                    Text("Description lookup")
                } footer: {
                    Text("Used by \"Search the web\" when you fetch a book's description. iOS doesn't reveal Safari's default engine, so LibraryCove keeps its own choice; DuckDuckGo is the default.")
                }
                Section {
                    if aiLogs.isEmpty {
                        Text("No AI activity logged yet. Ask a question or tap Test connection to see request logs here.")
                            .foregroundStyle(.secondary)
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

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About & Feedback", systemImage: "info.circle")
                    }
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
            .sheet(isPresented: $showSharingSheet) {
                if let share = shareSheetShare {
                    CloudSharingSheet(share: share)
                        .onDisappear {
                            Task { await refreshMembers() }
                        }
                }
            }
            .confirmationDialog("Stop sharing this library?",
                                isPresented: $showStopSharingConfirm,
                                titleVisibility: .visible) {
                Button("Stop Sharing", role: .destructive) {
                    Task { await stopSharingNow() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everyone with access loses the shared library. Your books return to your private library.")
            }
            .confirmationDialog("Leave this shared library?",
                                isPresented: $showLeaveConfirm,
                                titleVisibility: .visible) {
                Button("Keep a Copy & Leave") {
                    Task { await leaveSharedNow(keepCopy: true) }
                }
                Button("Leave without a Copy", role: .destructive) {
                    Task { await leaveSharedNow(keepCopy: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Keeping a copy adds the shared books to your private library (duplicates are skipped).")
            }
            .task {
                await refreshMembers()
            }
            .onChange(of: syncProvider) { _, newValue in
                switchSyncProvider(to: newValue)
            }
            .task(id: aiConfigSignature) {
                aiAvailability = await AIService.shared.availability()
                await reloadModels()
            }
            .onAppear {
                reloadLogs()
            }
            .onChange(of: aiEngine) { _, newValue in
                AIConfig.selectedEngine = newValue
            }
            .onChange(of: aiBaseURL) { _, newValue in
                AIConfig.openAIBaseURL = newValue
            }
            .onChange(of: aiAPIKey) { _, newValue in
                AIConfig.openAIAPIKey = newValue
            }
            .onChange(of: aiModel) { _, newValue in
                AIConfig.openAIModel = newValue
            }
            .onChange(of: contextWindow) { _, newValue in
                AIConfig.maxContextTokens = newValue
            }
            .onChange(of: searchEngine) { _, newValue in
                WebSearchEngine.selected = newValue
            }
            .alert("Restart to apply", isPresented: $showSyncRestartNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your library was captured. Quit and reopen LibraryCove to start using \(syncProvider.displayName); your data will be moved to that store when it relaunches.")
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

    // MARK: - AI connection testing + logs

    @MainActor
    private func reloadLogs() {
        // Newest first — the most recent request is what a user checking logs
        // actually cares about; it goes at the top rather than off-screen.
        aiLogs = AILogStore.entries().reversed()
    }

    /// Asks the configured endpoint for its model list so the Model picker and
    /// the "Will use …" line reflect what the server actually reports. The
    /// provider caches the answer briefly, so this isn't a network probe on
    /// every keystroke. Failures surface as an explanatory note rather than an
    /// alert — the endpoint may simply not implement GET /v1/models.
    @MainActor
    private func reloadModels() async {
        guard aiEngine == .openAI else {
            availableModelInfos = []
            modelListNote = nil
            return
        }
        guard !trimmedBaseURL.isEmpty else {
            availableModelInfos = []
            modelListNote = nil
            return
        }
        do {
            let provider = OpenAICompatibleProvider(baseURL: trimmedBaseURL,
                                                    apiKey: AIConfig.openAIAPIKey)
            availableModelInfos = try await provider.listModelInfos()
            modelListNote = nil
        } catch {
            availableModelInfos = []
            let detail = (error as? AIError)?.errorDescription ?? "network error"
            modelListNote = "Couldn't read the model list from this endpoint (\(detail)). It may not support GET /v1/models — pin a model above or check the URL."
        }
    }

    /// Fires one real request through the selected engine so the user gets
    /// immediate "did my endpoint actually work" feedback, and so the
    /// connection log below it captures the exact outcome/error.
    @MainActor
    private func testConnection() async {
        isTesting = true
        testResult = nil
        testResultIsError = false
        defer { isTesting = false }
        do {
            let response = try await AIService.shared.generate(
                AIPrompt(system: "You are a connectivity probe.",
                         user: "Reply with a single word: OK.")
            )
            let cleaned = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = cleaned.prefix(160)
            testResult = snippet.isEmpty
                ? "Connected (empty reply)"
                : "Connected — replied: \(snippet)\(cleaned.count > 160 ? "…" : "")"
            testResultIsError = false
        } catch let error as AIError {
            testResult = Self.testFailureMessage(error)
            testResultIsError = true
        } catch {
            testResult = error.localizedDescription
            testResultIsError = true
        }
        reloadLogs()
    }

    private static func testFailureMessage(_ error: AIError) -> String {
        switch error {
        case .notConfigured:
            return "Enter an endpoint URL first."
        case .network(let underlying):
            return "Could not reach the endpoint — \(underlying.localizedDescription). Check the URL and that the server is running."
        default:
            return error.errorDescription ?? "Connection failed."
        }
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

    // MARK: - Shared library (Notes-style sharing)

    private var sharedLibrarySection: some View {
        Section {
            switch SharedLibraryMembershipGate.membership {
            case .none:
                Button {
                    Task { await beginSharing() }
                } label: {
                    Label("Share Library", systemImage: "person.2")
                }
                .disabled(isPreparingShare || isSwitchingSync)
                if isPreparingShare {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Preparing your shared library…")
                            .foregroundStyle(.secondary)
                    }
                }
            case .owner:
                Button {
                    Task { await presentSharingSheet() }
                } label: {
                    Label("Manage Shared Library", systemImage: "person.2")
                }
                Button(role: .destructive) {
                    showStopSharingConfirm = true
                } label: {
                    Label("Stop Sharing", systemImage: "person.2.slash")
                }
            case .participant:
                LabeledContent("Shared Library",
                               value: SharedLibrarySettings.shareTitle ?? "Active")
                Button(role: .destructive) {
                    showLeaveConfirm = true
                } label: {
                    Label("Leave Shared Library", systemImage: "person.2.slash")
                }
            }

            if !sharedMembers.isEmpty {
                ForEach(sharedMembers) { member in
                    HStack {
                        Image(systemName: member.isOwner ? "crown" : "person")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(member.isCurrentUser ? "\(member.name) (you)" : member.name)
                            Text("\(member.acceptanceStatusDescription) · \(member.permissionDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let syncError = SharedLibraryEngine.shared.lastError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Shared Library")
        } footer: {
            Text(SharedLibraryMembershipGate.membership == .none
                 ? "Share your library with other people via iCloud. Everyone with access can add, edit, and remove books — changes sync to all members."
                 : "This library is shared via iCloud. Changes made by any member sync to everyone with access.")
        }
    }

    // MARK: - Shared library actions

    private func beginSharing() async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let share = try await SharedLibraryCoordinator.beginShare(
                currentTitle: "\(user.displayName)'s Library")
            shareSheetShare = share
            showSharingSheet = true
        } catch {
            lastError = error.localizedDescription
            showError = true
        }
    }

    private func presentSharingSheet() async {
        do {
            guard let share = try await SharedLibraryEngine.shared.currentShare() else {
                lastError = SharedLibraryError.notShared.errorDescription
                showError = true
                return
            }
            shareSheetShare = share
            showSharingSheet = true
        } catch {
            lastError = error.localizedDescription
            showError = true
        }
    }

    private func syncStatusText(_ provider: LibrarySync) -> String {
        switch provider {
        case .localOnly: return "Stored on this device"
        case .iCloud: return "Syncing via iCloud"
        case .sharedLibrary: return "Sharing via iCloud"
        case .dropbox, .box, .nextcloud: return "Not connected"
        }
    }

    private func stopSharingNow() async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            try await SharedLibraryCoordinator.stopSharing()
            showSyncRestartNotice = true
        } catch {
            lastError = error.localizedDescription
            showError = true
        }
    }

    private func leaveSharedNow(keepCopy: Bool) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            try await SharedLibraryCoordinator.leave(keepCopy: keepCopy)
            showSyncRestartNotice = true
        } catch {
            lastError = error.localizedDescription
            showError = true
        }
    }

    private func refreshMembers() async {
        await SharedLibraryEngine.shared.refreshParticipants()
        sharedMembers = SharedLibraryEngine.shared.members
    }

    // MARK: - Actions

    // MARK: - Sync

    private func switchSyncProvider(to new: LibrarySync) {
        guard new != SyncSettings.selectedProvider else { return }
        guard new.isAvailableNow else {
            // Not implemented providers: show why and revert the picker.
            lastError = LibrarySyncError.notImplementedFor(new).errorDescription
            showError = true
            syncProvider = SyncSettings.selectedProvider
            return
        }
        guard !isSwitchingSync else { return }
        isSwitchingSync = true
        Task { @MainActor in
            defer { isSwitchingSync = false }
            // Snapshot the current library (zip keeps cover files) so the data
            // moves into the target provider's store on relaunch.
            guard let snapshot = await LibraryDataService.export(context: modelContext),
                  SyncSettings.writeSnapshot(snapshot) else {
                syncProvider = SyncSettings.selectedProvider
                lastError = "Couldn't prepare your library for the switch. Nothing changed."
                showError = true
                return
            }
            SyncSettings.selectedProvider = new
            showSyncRestartNotice = true
        }
    }

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

/// SwiftUI wrapper for the standard CloudKit sharing sheet — the same UI
/// Notes/Freeform use: invite by iMessage/mail/link, per-person permissions,
/// remove participants.
struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    init(share: CKShare, container: CKContainer = CKContainer(identifier: SwiftDataiCloudSync.containerIdentifier)) {
        self.share = share
        self.container = container
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadOnly, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            SharedLibraryEngine.shared.reportError(error.localizedDescription)
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            SharedLibrarySettings.shareTitle
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { await SharedLibraryEngine.shared.refreshParticipants() }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            // User tapped "Stop Sharing" inside the system sheet.
            Task { @MainActor in
                do {
                    try await SharedLibraryCoordinator.stopSharing()
                } catch {
                    // The private library was left untouched (fail-safe);
                    // surface why instead of failing silently. Settings
                    // shows the engine's lastError.
                    SharedLibraryEngine.shared.reportError(error.localizedDescription)
                }
            }
        }
    }
}

/// Snapshot of the membership role for view bodies (Settings reads this in
/// `body`, where async engine state isn't directly available).
enum SharedLibraryMembershipGate {
    static var membership: SharedLibraryMembership {
        SharedLibrarySettings.membership
    }
}
