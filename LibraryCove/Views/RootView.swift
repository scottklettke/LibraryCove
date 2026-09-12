import SwiftUI
import SwiftData

/// Root view: auth gate → main tab layout.
struct RootView: View {
    @Query private var users: [User]

    /// True when the store has ANY member rows (active or not) — the app
    /// has been set up before. Only a completely fresh store (no member
    /// rows at all) shows the welcome flow.
    private var hasAnyMember: Bool {
        !users.isEmpty
    }
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if let currentUser = users.first(where: \.isActive) {
                MainTabView(user: currentUser)
            } else if hasAnyMember {
                // A store with members but no active user is a pre-welcome
                // install (or post-reset) — legacy login still applies.
                LoginView()
            } else {
                WelcomeView(onComplete: {})
            }
        }
        .task {
            resetDataIfNeeded()
            seedLibraryBooksIfNeeded(context: modelContext)
            // Older merge imports could leave two Book rows sharing one id,
            // which breaks copy discrimination on delete and id-based stale
            // snapshot guards. Repair before anything reads books.
            BookIDRepair.repairIfNeeded(context: modelContext)
            // Consolidate same-book duplicates left by pre-merge provider
            // switches (Local↔iCloud round trips re-inserted rows).
            BookDuplicateRepair.repairIfNeeded(context: modelContext)
            // Pour a provider-switch snapshot into the fresh store so the
            // library into the newly selected provider's store.
            SyncCoordinator.finishPendingMigrationIfNeeded(context: modelContext)
            // Clear sharing state orphaned by older builds (provider switched
            // away without tearing the share down) — otherwise Settings
            // shows Share Library controls under Local only.
            await SharedLibraryCoordinator.repairOrphanedMembershipIfNeeded()
            // Embed any still file-only covers as data URLs so iCloud Sync
            // pushes cover images to other devices. Skipped in shared mode:
            // the mirror's covers are fingerprint-tracked CKAsset copies and
            // must not be re-encoded as data: URLs.
            if SyncSettings.selectedProvider != .sharedLibrary {
                LibraryDataService.materializeLocalCovers(context: modelContext)
            }
            // Shared-library hooks: join a pending invitation (flips the
            // provider for next launch), then sync the mirror store.
            if SyncSettings.selectedProvider == .sharedLibrary {
                // A freshly-created mirror store has no User row, which would
                // show LoginView over the shared library — seed a placeholder
                // identity first (mirrors LoginView's defaults).
                ensureActiveUser(context: modelContext)
                await SharedLibraryCoordinator.processPendingAcceptIfNeeded()
                await SharedLibraryEngine.shared.syncNow(context: modelContext)
            } else if SharedLibrarySettings.pendingAcceptMetadata != nil {
                await SharedLibraryCoordinator.processPendingAcceptIfNeeded()
            }
            // Fix books whose dates were never stamped (sentinel 2001-01-01),
            // which rendered "date added" as 12/31/00.
            if let all = try? modelContext.fetch(FetchDescriptor<Book>()) {
                BookDateRepair.repairSentinelDates(books: all, context: modelContext)
            }
        }
    }

    /// Shared-library mirror stores start empty (participants pull everything
    /// from the cloud). Without a User row the login gate would cover the
    /// shared library with LoginView — seed a placeholder identity.
    private func ensureActiveUser(context: ModelContext) {
        let users = (try? context.fetch(FetchDescriptor<User>())) ?? []
        guard !users.contains(where: \.isActive) else { return }
        context.insert(User(email: "shared@librarycove.local",
                            displayName: SharedLibrarySettings.shareTitle ?? "Shared Library"))
        try? context.save()
    }


    /// UI-test seam: clear the library (and pending scans) at launch so
    /// deterministic offline UI tests always start from an empty store —
    /// previously records persisted across test runs and collided on re-run.
    private func resetDataIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TEST_RESET_DATA"] == "1" else { return }
        try? modelContext.delete(model: Book.self)
        try? modelContext.save()
        ScanQueueStore.shared.clear()
    }

    /// UI-test seam: seed the library with stored books at launch, so a
    /// test can start from a known book (e.g. one with no description)
    /// without driving the whole camera→queue→import flow. Mirrors the
    /// other UI_TEST_* seams: JSON in, silent no-op when unset.
    private func seedLibraryBooksIfNeeded(context: ModelContext) {
        guard let raw = ProcessInfo.processInfo.environment["UI_TEST_LIBRARY_BOOKS"],
              let data = raw.data(using: .utf8),
              let seeds = try? JSONDecoder().decode([SeededBook].self, from: data) else { return }
        for seed in seeds {
            context.insert(Book(id: seed.id, title: seed.title, authors: seed.authors,
                                isbn: seed.isbn, publicationYear: seed.publicationYear,
                                bookDescription: seed.bookDescription,
                                descriptionSource: seed.descriptionSource))
        }
        try? context.save()
    }

    private struct SeededBook: Decodable {
        let id: String
        let title: String
        let authors: [String]
        let isbn: String?
        let publicationYear: Int?
        let bookDescription: String?
        let descriptionSource: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            authors = try c.decode([String].self, forKey: .authors)
            isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
            publicationYear = try c.decodeIfPresent(Int.self, forKey: .publicationYear)
            bookDescription = try c.decodeIfPresent(String.self, forKey: .bookDescription)
            descriptionSource = try c.decodeIfPresent(String.self, forKey: .descriptionSource)
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, authors, isbn, publicationYear, bookDescription, descriptionSource
        }
    }
}

/// Simple placeholder login that creates a local family member.
struct LoginView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var email = ""
    @State private var displayName = ""
    @State private var isRegistering = false

    var body: some View {
        Form {
            Section("Family member") {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                TextField("Display name", text: $displayName)
            }
            Button("Enter library") {
                let user = User(email: email.isEmpty ? "local@librarycove.local" : email,
                                displayName: displayName.isEmpty ? "Family member" : displayName)
                modelContext.insert(user)
                try? modelContext.save()
            }
            .disabled(!isRegistering == false && email.isEmpty && displayName.isEmpty)
        }
    }
}

/// Main tab layout: Library, Ask AI, Settings.
struct MainTabView: View {
    let user: User

    @State private var selectedTab: AppTab = .library

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(AppTab.library)
            NavigationStack {
                AIAskView()
            }
            .tabItem { Label("Ask AI", systemImage: "sparkles") }
            .tag(AppTab.askAI)
            .environment(\.openLibraryTab, { selectedTab = .library })
            SettingsView(user: user)
                .tabItem { Label("Settings", systemImage: "gear") }
                .environment(\.openLibraryTab, { selectedTab = .library })
                .tag(AppTab.settings)
        }
    }
}

/// The top-level navigation destinations, used to switch tabs programmatically.
enum AppTab: Hashable {
    case library
    case askAI
    case settings
}

/// Lets a tab (e.g. "Ask AI") hand the user back to the Library tab.
struct OpenLibraryTabKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openLibraryTab: () -> Void {
        get { self[OpenLibraryTabKey.self] }
        set { self[OpenLibraryTabKey.self] = newValue }
    }
}
