import SwiftUI
import SwiftData
import CloudKit

/// Settings screen: profile, library data (export/import/delete), sync and AI.
struct SettingsView: View {
    let user: User
    @Environment(\.modelContext) private var modelContext
    /// Switches the root TabView to the Library tab (used after Delete
    /// Library so the user lands on the empty-library page).
    @Environment(\.openLibraryTab) private var openLibraryTab
    // Delete
    @State private var showDeleteLibraryConfirm = false
    /// Shown when Delete Library is tapped with nothing to delete.
    @State private var showLibraryAlreadyEmpty = false
    @State private var isDeleting = false

    @FocusState private var nameFieldFocused: Bool

    // Sync
    @State private var syncProvider: LibrarySync = SyncSettings.selectedProvider
    @State private var isSwitchingSync = false
    /// A provider change while a share is active — held for the
    /// "this stops sharing" confirmation before it is applied.
    @State private var pendingProviderChange: LibrarySync?

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
    @ObservedObject private var cloudSyncMonitor = CloudSyncMonitor.shared

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
                profileSection

                dataSection

                syncSection

                if syncProvider == .iCloud || SharedLibraryMembershipGate.membership != .none {
                    sharedLibrarySection
                }

                aiEngineSection

                trailingSections

            }
            .navigationTitle("Settings")
            .alert("Nothing to delete", isPresented: $showLibraryAlreadyEmpty) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your library is already empty — there are no books, notes, reading lists, or connections to delete.")
            }
            .sheet(isPresented: $showDeleteLibraryConfirm) {
                DeleteLibrarySheet(
                    sharingActive: SharedLibraryMembershipGate.membership != .none,
                    hasBackups: !BackupStore.list().isEmpty
                ) {
                    deleteLibraryData()
                }
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
                cloudSyncMonitor.start()
                await refreshMembers()
            }
            .onChange(of: syncProvider) { _, newValue in
                switchSyncProvider(to: newValue)
            }
            .task(id: aiConfigSignature) {
                aiAvailability = await AIService.shared.availability()
                await reloadModels()
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
            .alert("Done", isPresented: $showResult) {
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
            // The user's chosen library name (welcome flow) wins; fall back
            // to the classic "<Name>'s Library".
            let title = SharedLibrarySettings.preferredShareTitle
                ?? "\(user.displayName)'s Library"
            let share = try await SharedLibraryCoordinator.beginShare(
                currentTitle: title)
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

    /// Live iCloud sync status: while an NSPersistentCloudKitContainer
    /// event runs, show what's happening with a progress bar; when idle,
    /// show the synced state (or the last error).
    @ViewBuilder
    private var iCloudSyncStatusRow: some View {
        if let activity = cloudSyncMonitor.activity {
            VStack(alignment: .leading, spacing: 6) {
                Text(activity.kind.displayName)
                    .font(.callout)
                ProgressView()
                    .progressViewStyle(.linear)
            }
            .padding(.vertical, 2)
        } else if let lastError = cloudSyncMonitor.lastError {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync problem")
                    .font(.callout)
                    .foregroundStyle(.red)
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else {
            LabeledContent("Status", value: "Synced with iCloud")
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
            lastResult = "Sharing stopped. Your books are back in your private library."
            showResult = true
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
            lastResult = keepCopy
                ? "You left the shared library. A copy of the shared books was added to your library."
                : "You left the shared library."
            showResult = true
        } catch {
            lastError = error.localizedDescription
            showError = true
        }
    }

    /// Books + notes + reading lists + list items + connections — the exact
    /// scope of "Delete Library".
    private var libraryContentCount: Int {
        ((try? modelContext.fetchCount(FetchDescriptor<Book>())) ?? 0)
            + ((try? modelContext.fetchCount(FetchDescriptor<Note>())) ?? 0)
            + ((try? modelContext.fetchCount(FetchDescriptor<ReadingList>())) ?? 0)
            + ((try? modelContext.fetchCount(FetchDescriptor<ReadingListItem>())) ?? 0)
            + ((try? modelContext.fetchCount(FetchDescriptor<Connection>())) ?? 0)
    }

    private func refreshMembers() async {
        await SharedLibraryEngine.shared.refreshParticipants()
        sharedMembers = SharedLibraryEngine.shared.members
    }

    // MARK: - Actions

    private func switchSyncProvider(to new: LibrarySync) {
        guard new != SyncSettings.selectedProvider else { return }
        // A share is active: switching to another provider stops sharing it
        // with everyone. Confirm before tearing anything down.
        if SharedLibraryMembershipGate.membership != .none {
            pendingProviderChange = new
            return
        }
        performSwitch(to: new)
    }

    private func performSwitch(to new: LibrarySync) {
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
            do {
                try await ProviderSwitcher.perform(to: new)
                syncProvider = new
            } catch let error as LibrarySyncError {
                // Known, explained conditions (e.g. iCloudStillSyncing):
                // show their own message instead of the generic one.
                syncProvider = SyncSettings.selectedProvider
                lastError = error.errorDescription
                showError = true
            } catch {
                // Nothing changed (the switcher rolls back atomically).
                syncProvider = SyncSettings.selectedProvider
                lastError = "Couldn't move your library to the new store. Nothing changed."
                showError = true
            }
        }
    }

    /// Confirmed: switching providers while a share is active stops sharing
    /// the library with everyone. Tear the share down properly (owner: the
    /// zone + share are removed and books return home; participant: leaves
    /// with a copy), then apply the requested provider switch.
    private func confirmedProviderChange() {
        guard let target = pendingProviderChange else { return }
        pendingProviderChange = nil
        // Revert the picker immediately; the teardown/switch below sets it
        // to the final state.
        syncProvider = SyncSettings.selectedProvider
        Task { @MainActor in
            do {
                switch SharedLibraryMembershipGate.membership {
                case .owner:
                    try await SharedLibraryCoordinator.stopSharing()
                case .participant:
                    try await SharedLibraryCoordinator.leave(keepCopy: true)
                case .none:
                    break
                }
            } catch {
                lastError = error.localizedDescription
                showError = true
                return
            }
            // Teardown restored the pre-share provider; if the user asked
            // for a different one, run the normal switch on top.
            syncProvider = SyncSettings.selectedProvider
            if target != SyncSettings.selectedProvider {
                performSwitch(to: target)
            }
        }
    }

    private var trailingSections: some View {
        Group {
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
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label("Advanced", systemImage: "gearshape.2")
                    }
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About & Feedback", systemImage: "info.circle")
                    }
                }
        }
    }

    @ViewBuilder
    private var profileSection: some View {
                Section {
                    HStack {
                        TextField("Library name",
                                  text: Binding(get: {
                                                      LibraryScope.activeName(
                                                          context: modelContext,
                                                          memberName: user.displayName)
                                                  },
                                                  set: { newValue in
                                                      // The name names the ACTIVE
                                                      // library; other libraries keep
                                                      // theirs. The member display name
                                                      // (used for "Added by") stays
                                                      // bound to the library name for
                                                      // single-library users via
                                                      // LibraryScope.activeName's
                                                      // default.
                                                      LibraryScope.rename(
                                                          id: LibraryScope.activeID(context: modelContext),
                                                          to: newValue,
                                                          context: modelContext)
                                                      // A rename also applies to EVERY
                                                      // User row: CloudKit stores may
                                                      // hold older identity records for
                                                      // the same person, and mirroring
                                                      // would otherwise clobber the
                                                      // renamed row with a stale name.
                                                      let allUsers = (try? modelContext.fetch(FetchDescriptor<User>())) ?? []
                                                      for row in allUsers { row.displayName = newValue }
                                                      // Persist immediately so the
                                                      // empty-page greeting follows
                                                      // the rename.
                                                      try? modelContext.save()
                                                      // Keep the share-title default
                                                      // in sync when it was derived
                                                      // from the old name ("Scott's
                                                      // Library" -> "Bob's Library");
                                                      // a custom name is left alone.
                                                      let oldName = user.displayName
                                                      let derived = SharedLibrarySettings
                                                          .defaultShareTitle(for: oldName)
                                                      if SharedLibrarySettings.preferredShareTitle == nil
                                                          || SharedLibrarySettings.preferredShareTitle == derived {
                                                          SharedLibrarySettings.preferredShareTitle =
                                                              SharedLibrarySettings.defaultShareTitle(for: newValue)
                                                      }
                                                  }))
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
                    Text("Tap the pencil to edit the active library's name. Use Libraries below to switch between libraries.")
                }

                Section {
                    NavigationLink {
                        LibraryListView()
                    } label: {
                        Label("Libraries", systemImage: "books.vertical")
                    }
                } footer: {
                    Text("Create and switch between libraries. The active library's books are what you see everywhere in the app.")
                }
    }

    private var dataSection: some View {
                Section {
                    Button(role: .destructive) {
                        // Nothing to delete: say so instead of showing a
                        // destructive dialog for content that doesn't exist.
                        if libraryContentCount == 0 {
                            showLibraryAlreadyEmpty = true
                        } else {
                            showDeleteLibraryConfirm = true
                        }
                    } label: {
                        Label("Delete Library", systemImage: "trash")
                    }
                    .disabled(isDeleting)

                    NavigationLink {
                        BackupsView()
                    } label: {
                        Label("Backups", systemImage: "externaldrive")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export and Import live under Backups, together with your saved backups. Delete Library removes every book (with notes and lists) but keeps your member profile.")
                }
    }

    private var syncSection: some View {
                Section {
                    // While a share is active the provider IS the shared
                    // mirror; the picker (which excludes .sharedLibrary)
                    // would render blank. Show read-only status and route
                    // any change through the Stop Sharing confirmation.
                    if SharedLibraryMembershipGate.membership != .none {
                        LabeledContent("Sync provider", value: "Shared Library")
                        LabeledContent("Status", value: syncStatusText(syncProvider))
                    } else if syncProvider == .iCloud {
                        Picker("Sync provider", selection: $syncProvider) {
                            ForEach(LibrarySync.allCases.filter { $0 != .sharedLibrary && $0 != .localOnly }) { provider in
                                Text(provider.isAvailableNow
                                     ? provider.displayName
                                     : "\(provider.displayName) (coming soon)")
                                    .tag(provider)
                            }
                        }
                        iCloudSyncStatusRow
                    } else {
                        Picker("Sync provider", selection: $syncProvider) {
                            ForEach(LibrarySync.allCases.filter { $0 != .sharedLibrary && $0 != .localOnly }) { provider in
                                Text(provider.isAvailableNow
                                     ? provider.displayName
                                     : "\(provider.displayName) (coming soon)")
                                    .tag(provider)
                            }
                        }
                        LabeledContent("Status", value: syncStatusText(syncProvider))
                        .confirmationDialog(
                            "Stop sharing this library?",
                            isPresented: Binding(
                                get: { pendingProviderChange != nil },
                                set: { if !$0 { pendingProviderChange = nil; syncProvider = SyncSettings.selectedProvider } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Stop Sharing & Switch", role: .destructive) {
                                confirmedProviderChange()
                            }
                            Button("Cancel", role: .cancel) {
                                pendingProviderChange = nil
                                syncProvider = SyncSettings.selectedProvider
                            }
                        } message: {
                            Text("Changing the sync provider while a library is shared stops sharing it with everyone. Your books stay in your library — choose where to sync them next.")
                        }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Local only keeps everything on this device. iCloud Sync stores your library in your private iCloud database and keeps devices in sync. Dropbox, Box, and Nextcloud are coming soon.")
                }
    }

    private var aiEngineSection: some View {
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

    /// A provider switch copies the library between the local
    /// (default.store) and iCloud (default-cloud.store) stores via merge —
    /// so after any switch, BOTH stores hold the books. Deleting only the
    /// live store would leave a full copy in the other one, resurfacing on
    /// the next switch. This clears whichever store is NOT currently live.
    private func clearNonLiveStore(liveProvider: LibrarySync, contentOnly: Bool) {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
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

    private func deleteLibraryData() {
        isDeleting = true
        SyncSettings.markBulkChange()
        // Clear the LIVE store first: the UI reads from Persistence.shared,
        // so the empty state appears immediately.
        // (Backup deletion is governed by the sheet's "Keep saved backups"
        // toggle, which calls BackupStore.deleteAll() itself.)
        // Multi-library: Delete Library removes the ACTIVE library's
        // content only — other libraries are untouched.
        LibraryDataService.deleteActiveLibraryContent(context: modelContext)
        clearNonLiveStore(liveProvider: SyncSettings.selectedProvider, contentOnly: true)
        wipeAIRemnantsAndSearchHistory()
        if SharedLibraryMembershipGate.membership != .none {
            Task { @MainActor in
                do {
                    try await SharedLibraryCoordinator.discardSharedContent()
                    let context = try SharedLibraryCoordinator.privateContextAfterDiscard()
                    LibraryDataService.deleteLibraryContent(context: context)
                } catch {
                    lastError = error.localizedDescription
                    showError = true
                }
                isDeleting = false
                // Land the user on the (now empty) Library page.
                openLibraryTab()
            }
        } else {
            isDeleting = false
            openLibraryTab()
        }
    }
}

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
