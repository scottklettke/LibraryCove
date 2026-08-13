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
        }
    }

    /// UI-test seam: clear the library (and pending scans) at launch so
    /// deterministic offline UI tests always start from an empty store —
    /// previously records persisted across test runs and collided on re-run.
    private func resetDataIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TEST_RESET_DATA"] == "1" else { return }
        try? modelContext.delete(model: Book.self)
        try? modelContext.save()
        PendingScanStore.clear()
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

/// Main tab layout: Library, Notes, Lists, Graph, Settings.
struct MainTabView: View {
    let user: User

    var body: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }
            SettingsView(user: user)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
