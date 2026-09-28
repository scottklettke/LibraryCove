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
    @State private var isDeleting = false

    @FocusState private var nameFieldFocused: Bool

    // Sync
    @State private var syncProvider: LibrarySync = SyncSettings.selectedProvider
    @State private var isSwitchingSync = false
    /// A provider change while a share is active — held for the
    /// "this stops sharing" confirmation before it is applied.
    @State private var pendingProviderChange: LibrarySync?

    // Shared library
    @State private var sharedMembers: [SharedLibraryMember] = []
    @State private var isPreparingShare = false
    @State private var showSharingSheet = false
    @State private var shareSheetShare: CKShare?
    /// First-share role picker: what the LINK grants (admin/editor/guest).
    @State private var showLinkRolePicker = false
    @State private var pendingLinkRole: ShareParticipantRole = .editor
    @State private var pendingShareLibraryID: String?

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
    // Hardcover enrichment
    @State private var hardcoverToken: String = HardcoverConfig.token ?? ""
    @State private var isTestingHardcover = false
    @State private var hardcoverTestResult: String?
    @State private var hardcoverTestIsError = false

    // Description lookup
    @State private var searchEngine: WebSearchEngine = WebSearchEngine.selected

    // Feedback
    @State private var lastError: String?
    @State private var showError = false
    @ObservedObject private var cloudSyncMonitor = CloudSyncMonitor.shared
    /// Bumped whenever the library registry changes (switch/rename) so the
    /// name field re-reads the active library.
    @State private var libraryRegistryTick = 0
    /// The active library, or nil when no library exists (the no-library
    /// state replaces the rename field with Create Library). Re-read on
    /// registry changes via libraryRegistryTick.
    private var activeLibrary: LibraryInfo? {
        _ = libraryRegistryTick
        return LibraryScope.shared.active(context: modelContext)
    }
    /// Create-library sheet (offered when the registry is empty).
    @State private var showCreateLibrary = false
    @State private var newLibraryName = ""
    /// Set when the typed name matches another library's — warns instead of
    /// silently creating a confusing duplicate name.
    @State private var duplicateNameWarning: String?

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
                sharedLibrarySection
                dataSection

                syncSection

                aiEngineSection

                hardcoverSection

                trailingSections

            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSharingSheet) {
                if let share = shareSheetShare,
                   let libraryID = LibraryScope.shared.activeID(context: modelContext) {
                    CloudSharingSheet(share: share,
                                      libraryID: libraryID)
                        .onDisappear {
                            Task { await refreshMembers() }
                        }
                }
            }
            .sheet(isPresented: $showLinkRolePicker) {
                NavigationStack {
                    Form {
                        Section {
                            Picker("Link access", selection: $pendingLinkRole) {
                                Text("Admin — full control").tag(ShareParticipantRole.admin)
                                Text("Editor — can edit").tag(ShareParticipantRole.editor)
                                Text("Guest — view only").tag(ShareParticipantRole.guest)
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } header: {
                            Text("Who can use this link?")
                        } footer: {
                            Text("Anyone who joins through this link gets this role. You can change each member's role later in Members.")
                        }
                        Section {
                            Button {
                                Task { await createShareWithRole() }
                            } label: {
                                if isPreparingShare {
                                    HStack { Spacer(); ProgressView() }
                                } else {
                                    Text("Continue").frame(maxWidth: .infinity)
                                }
                            }
                            .disabled(isPreparingShare)
                        }
                    }
                    .navigationTitle("Share Library")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showLinkRolePicker = false }
                        }
                    }
                    .interactiveDismissDisabled(isPreparingShare)
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showDeleteLibraryConfirm) {
                DeleteLibrarySheet(
                    sharingActive: SharedLibraryMembershipGate.membership != .none,
                    hasBackups: !BackupStore.list().isEmpty
                ) {
                    deleteLibraryData()
                }
            }
            .sheet(isPresented: $showCreateLibrary) {
                createLibrarySheet
            }
            .task {
                cloudSyncMonitor.start()
                await refreshMembers()
            }
            .onReceive(NotificationCenter.default.publisher(for: LibraryScope.librariesChangedNotification)) { _ in
                libraryRegistryTick += 1
                // The active library may have switched — its members differ.
                Task { await refreshMembers() }
            }
            .alert("Library name already used", isPresented: Binding(
                get: { duplicateNameWarning != nil },
                set: { if !$0 { duplicateNameWarning = nil } }
            )) {
                Button("Continue anyway", role: .cancel) {}
            } message: {
                Text(duplicateNameWarning ?? "")
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

    /// Persists the pasted Hardcover PAT to the Keychain, then verifies it
    /// with the cheapest possible read-catalog query.
    @MainActor
    private func testHardcoverConnection() async {
        let token = hardcoverToken.trimmingCharacters(in: .whitespaces)
        HardcoverConfig.token = token.isEmpty ? nil : token
        isTestingHardcover = true
        defer { isTestingHardcover = false }
        let error = await HardcoverService().testConnection()
        hardcoverTestIsError = error != nil
        hardcoverTestResult = error ?? "Connected — Hardcover enrichment active."
    }

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

    /// Warns when the active library's (typed) name matches ANOTHER
    /// library's — duplicate names make the Libraries list ambiguous.
    private func checkDuplicateName() {
        guard let typed = LibraryScope.shared.activeName(
            context: modelContext,
            memberName: user.displayName),
              let activeID = LibraryScope.shared.activeID(context: modelContext)
        else { return }
        if let clash = LibraryScope.shared.all(context: modelContext).first(where: {
            $0.id != activeID
                && $0.name.compare(typed, options: .caseInsensitive) == .orderedSame
        }) {
            duplicateNameWarning = "Another library is already named “\(clash.name)”. Two libraries with the same name can be confusing in Backups and switching — consider a distinct name."
        }
    }


    /// Share (first time) or manage (existing share) the ACTIVE library —
    /// the same flow as the Libraries-list long-press: fetch the share,
    /// creating it when absent, and present the sharing sheet.
    private func shareOrManageActive() async {
        guard let active = LibraryScope.shared.active(context: modelContext) else { return }
        do {
            if let share = try await SharedLibraryEngine.shared.currentShare(libraryID: active.id) {
                shareSheetShare = share
                showSharingSheet = true
            } else {
                // First share: let the owner pick what the LINK grants
                // (admin/editor/guest) before the system sheet offers the
                // contact/link options. The choice is written into the
                // zone's roles record by makeShare, so joiners adopt it.
                pendingLinkRole = SharedLibrarySettings.linkDefaultRole(libraryID: active.id)
                pendingShareLibraryID = active.id
                showLinkRolePicker = true
            }
        } catch {
            lastError = error.localizedDescription
            showError = true
        }
    }

    /// Called from the role pre-sheet's Continue: creates the share with
    /// the picked link role and presents the system sharing sheet.
    private func createShareWithRole() async {
        guard let libraryID = pendingShareLibraryID else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            SharedLibrarySettings.setLinkDefaultRole(pendingLinkRole, libraryID: libraryID)
            shareSheetShare = try await SharedLibraryCoordinator.beginShare(
                currentTitle: LibraryScope.shared.active(context: modelContext)?.name ?? "Library",
                libraryID: libraryID,
                linkRole: pendingLinkRole)
            showLinkRolePicker = false
            showSharingSheet = true
        } catch {
            lastError = error.localizedDescription
            showError = true
        }
    }

    private func refreshMembers() async {
        // Clear first: while the fetch runs, showing the PREVIOUS active
        // library's members would be wrong.
        sharedMembers = []
        if let libraryID = LibraryScope.shared.activeID(context: modelContext) {
            await SharedLibraryEngine.shared.refreshParticipants(libraryID: libraryID)
        }
        sharedMembers = SharedLibraryEngine.shared.members
    }
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
                        TextField("Your name",
                                  text: Binding(get: { user.displayName },
                                                set: { newValue in
                                                    // The member display name is used
                                                    // for "Hi, <name>" and "Added by"
                                                    // attribution. Applies to EVERY
                                                    // User row: CloudKit stores may hold
                                                    // older identity records for the same
                                                    // person, and mirroring would otherwise
                                                    // clobber the renamed row.
                                                    let allUsers = (try? modelContext.fetch(FetchDescriptor<User>())) ?? []
                                                    for row in allUsers { row.displayName = newValue }
                                                    try? modelContext.save()
                                                }))
                            .focused($nameFieldFocused)
                        Button {
                            nameFieldFocused = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit your name")
                    }
                } header: {
                    Text("Your Name")
                } footer: {
                    Text("Shown in the greeting on your library's home page and used for “Added by” on your books.")
                }

                Section {
                    if let activeLibrary = activeLibrary {
                        HStack {
                            TextField("Library name",
                                      text: Binding(get: {
                                          _ = libraryRegistryTick
                                          return activeLibrary.name
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
                                          LibraryScope.shared.rename(
                                              id: activeLibrary.id,
                                              to: newValue,
                                              context: modelContext)
                                      }))
                                .focused($nameFieldFocused)
                                .onSubmit {
                                    checkDuplicateName()
                                }
                            Button {
                                nameFieldFocused = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit library name")
                        }
                    } else {
                        // No library exists (deleted the last one): say so
                        // and offer creation instead of an orphaned rename
                        // field over a phantom "Untitled" entry.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No library")
                                .foregroundStyle(.secondary)
                            Button {
                                showCreateLibrary = true
                            } label: {
                                Label("Create Library", systemImage: "plus")
                            }
                        }
                    }
                } header: {
                    Text("Active Library")
                } footer: {
                    Text(activeLibrary == nil
                         ? "Create a library to start adding books."
                         : "Tap the pencil to rename the active library. Use Libraries below to switch between libraries.")
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


    /// Share entry for the ACTIVE library, on the per-library sharing model:
    /// membership keyed by the active library's id, same
    /// currentShare(libraryID:)/beginShare(currentTitle:libraryID:) flow as
    /// the Libraries-list long-press. Stop/Leave stay in the Libraries list
    /// until the coordinator gains libraryID-scoped destructive flows.
    private var sharedLibrarySection: some View {
        Section {
            let active = LibraryScope.shared.active(context: modelContext)
            let membership = active.map {
                SharedLibrarySettings.membership(libraryID: $0.id)
            } ?? .none
            let role = active.map {
                SharedLibraryEngine.shared.myRole(libraryID: $0.id)
            } ?? .guest
            switch membership {
            case .none:
                Button {
                    Task { await shareOrManageActive() }
                } label: {
                    Label("Share Library", systemImage: "person.2")
                }
                .disabled(isPreparingShare || isSwitchingSync || active == nil)
                if isPreparingShare {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Preparing your shared library…")
                            .foregroundStyle(.secondary)
                    }
                }
            case .owner:
                Button {
                    Task { await shareOrManageActive() }
                } label: {
                    Label("Manage Shared Library", systemImage: "person.2")
                }
            case .participant:
                LabeledContent("Shared Library",
                               value: active?.name.isEmpty == false
                                      ? (active?.name ?? "Active")
                                      : "Active")
                // Admins and editors can share links (guests can't — the
                // sheet's permission is read-only for them anyway).
                if role != .guest {
                    Button {
                        Task { await shareOrManageActive() }
                    } label: {
                        Label("Share Link", systemImage: "link")
                    }
                }
            }

            if membership != .none && !sharedMembers.isEmpty {
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
            Text(SharedLibrarySettings.membership(
                     libraryID: LibraryScope.shared.activeID(context: modelContext) ?? "") == .none
                 ? "Share this library with other people via iCloud. Everyone with access can add, edit, and remove books — changes sync to all members."
                 : "This library is shared via iCloud. Changes made by any member sync to everyone with access.")
        }
    }

    /// Create-library sheet (no-library state in Settings, or a fresh
    /// install): a name field and a Create button. Extracted into its own
    /// property so the giant body expression type-checks in reasonable
    /// time.
    private var createLibrarySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Library name", text: $newLibraryName)
                } footer: {
                    Text("It starts empty and becomes the active library.")
                }
                Section {
                    Button {
                        let name = newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        _ = try? LibraryScope.shared.create(
                            name: name, makeActive: true, context: modelContext)
                        newLibraryName = ""
                        showCreateLibrary = false
                    } label: {
                        Text("Create library")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("New library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        newLibraryName = ""
                        showCreateLibrary = false
                    }
                }
            }
            .interactiveDismissDisabled(false)
        }
        .presentationDetents([.medium])
    }

    private var dataSection: some View {
                Section {
                    Button(role: .destructive) {
                        showDeleteLibraryConfirm = true
                    } label: {
                        Label("Delete Library", systemImage: "trash")
                    }
                    .disabled(isDeleting || activeLibrary == nil)

                    NavigationLink {
                        BackupsView()
                    } label: {
                        Label("Backups", systemImage: "externaldrive")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export and Import live under Backups, together with your saved backups. Delete Library removes this library — every book (with notes and lists) in it — and takes it off your Libraries list. Your member profile is kept. An empty library is removed too, leaving the Libraries list without it.")
                }
    }

    private var syncSection: some View {
                Section {
                    // While a share is active the provider IS the shared
                    // mirror; the picker (which excludes .sharedLibrary)
                    // would render blank. Show read-only status and route
                    // any change through the Stop Sharing confirmation.
                    if SharedLibrarySettings.membership(
                           libraryID: LibraryScope.shared.activeID(context: modelContext) ?? "") != .none {
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

    /// Optional enrichment source: Hardcover's public catalog (genres, tags,
    /// series) layered on top of OpenLibrary/Google lookups. Off until the
    /// user supplies their own PAT — the API has no shared app key.
    private var hardcoverSection: some View {
        Section {
            Toggle("Use Hardcover for book details", isOn: Binding(
                get: { HardcoverConfig.isEnabled },
                set: { HardcoverConfig.isEnabled = $0 }
            ))
            if HardcoverConfig.isEnabled {
                SecureField("API key", text: $hardcoverToken, prompt: Text("Paste your Hardcover key"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("hardcoverTokenField")
                Button {
                    Task { await testHardcoverConnection() }
                } label: {
                    Label(isTestingHardcover ? "Testing…" : "Test connection",
                          systemImage: isTestingHardcover ? "arrow.triangle.2.circlepath" : "bolt.fill")
                }
                .disabled(isTestingHardcover || hardcoverToken.trimmingCharacters(in: .whitespaces).isEmpty)
                if let hardcoverTestResult {
                    LabeledContent(hardcoverTestIsError ? "Test failed" : "Test result") {
                        Text(hardcoverTestResult)
                            .font(.caption)
                            .foregroundStyle(hardcoverTestIsError ? Color.red : Color.green)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        } header: {
            Text("Hardcover")
        } footer: {
            Text("Enriches scanned and imported books with Hardcover's curated genres, tags, series, and extra details. Create a free API key at hardcover.app → Account → API (New API Key) and paste it here; the key is stored in your device's Keychain and only public book data is read — never your Hardcover ratings or reviews.")
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
    /// the next switch. This clears the doomed library's rows from
    /// whichever store is NOT currently live; other libraries keep their
    /// rows (their copies surface on the next provider-switch merge).
    private func clearNonLiveStore(liveProvider: LibrarySync, contentOnly: Bool,
                                   libraryID: String) {
        let otherProvider: LibrarySync = liveProvider == .iCloud ? .localOnly : .iCloud
        let container = SyncStoreRegistry.makeContainer(for: otherProvider)
        if contentOnly {
            // Scope to the one library: on a shared-library teardown the
            // non-live store is the post-discard destination and holds the
            // only copies of the REMAINING libraries' rows.
            LibraryDataService.deleteLibraryContent(
                context: ModelContext(container),
                libraryID: libraryID)
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
        // Capture the doomed library BEFORE deleting content: the shared
        // branch below reads SharedLibraryMembershipGate.membership for it,
        // and LibraryScope.delete would switch the active library first.
        let doomed = LibraryScope.shared.active(context: modelContext)
        LibraryDataService.deleteActiveLibraryContent(context: modelContext)
        clearNonLiveStore(liveProvider: SyncSettings.selectedProvider, contentOnly: true,
                          libraryID: doomed?.id ?? "")
        wipeAIRemnantsAndSearchHistory()
        if SharedLibraryMembershipGate.membership != .none {
            Task { @MainActor in
                do {
                    try await SharedLibraryCoordinator.discardSharedContent()
                    let context = try SharedLibraryCoordinator.privateContextAfterDiscard()
                    // Destination store holds every library's rows (the
                    // mirror held only the shared library) — wipe just the
                    // doomed library's rows, not all libraries' content.
                    LibraryDataService.deleteLibraryContent(
                        context: context,
                        libraryID: doomed?.id ?? "")
                } catch {
                    lastError = error.localizedDescription
                    showError = true
                }
                // Remove the library itself so it disappears from the
                // Libraries list; the oldest remaining library becomes
                // active, or the no-library state when none remain.
                if let doomed {
                    LibraryScope.shared.delete(doomed, context: modelContext)
                }
                isDeleting = false
                // Land the user on the (now empty) Library page.
                openLibraryTab()
            }
        } else {
            if let doomed {
                LibraryScope.shared.delete(doomed, context: modelContext)
            }
            isDeleting = false
            openLibraryTab()
        }
    }
}

struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    /// The active library at presentation time — its share this sheet
    /// manages; delegates refresh that library's participants.
    let libraryID: String
    let container: CKContainer

    init(share: CKShare, libraryID: String, container: CKContainer = CKContainer(identifier: SwiftDataiCloudSync.containerIdentifier)) {
        self.share = share
        self.libraryID = libraryID
        self.container = container
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadOnly, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(libraryID: libraryID) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let libraryID: String
        init(libraryID: String) { self.libraryID = libraryID }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            SharedLibraryEngine.shared.reportError(error.localizedDescription)
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            SharedLibrarySettings.shareTitle
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { await SharedLibraryEngine.shared.refreshParticipants(libraryID: libraryID) }
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
