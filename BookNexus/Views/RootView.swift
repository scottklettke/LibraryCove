import SwiftUI
import SwiftData

/// Root view: auth gate → main tab layout.
struct RootView: View {
    @Query private var users: [User]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if let currentUser = users.first(where: \.isActive) {
                MainTabView(user: currentUser)
            } else {
                LoginView()
            }
        }
        .task {
            resetDataIfNeeded()
            // On relaunch after a sync-provider change: pour the captured
            // library into the newly selected provider's store.
            SyncCoordinator.finishPendingMigrationIfNeeded(context: modelContext)
            // Embed any still file-only covers as data URLs so iCloud Sync
            // pushes cover images to other devices.
            LibraryDataService.materializeLocalCovers(context: modelContext)
            // Fix books whose dates were never stamped (sentinel 2001-01-01),
            // which rendered "date added" as 12/31/00.
            if let all = try? modelContext.fetch(FetchDescriptor<Book>()) {
                BookDateRepair.repairSentinelDates(books: all, context: modelContext)
            }
        }
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
                let user = User(email: email.isEmpty ? "local@booknexus.local" : email,
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
private struct OpenLibraryTabKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openLibraryTab: () -> Void {
        get { self[OpenLibraryTabKey.self] }
        set { self[OpenLibraryTabKey.self] = newValue }
    }
}
