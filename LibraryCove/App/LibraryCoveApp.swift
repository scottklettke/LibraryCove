import SwiftData
import SwiftUI
import UIKit

/// App delegate: remote-notification registration only (Pears does not
/// use it today, but removing it changes background-mode plumbing; the
/// registration is harmless). All CloudKit share-accept plumbing is
/// retired with iCloud sharing.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }
}

@main
struct LibraryCoveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var shareAcceptDelegate
    // @State so SwiftUI re-renders the scene when the store is hot-swapped
    // after a sync-provider switch (Persistence.swapShared posts
    // .syncStoreSwapped; the onReceive below picks up the new container).
    @State private var container: ModelContainer = Persistence.shared
    /// Holds RootView until the launch-time degrade check below finished.
    /// Without the gate, RootView renders (and its .task resets/seeds) against
    /// the pre-degrade CloudKit container, then the swap re-renders it on the
    /// local store — seeds and resets landed on the wrong store.
    @State private var storeReady = false

    var body: some Scene {
        WindowGroup {
            if storeReady {
                RootView()
                    .onReceive(NotificationCenter.default.publisher(for: Persistence.storeSwappedNotification)) { _ in
                        container = Persistence.shared
                    }
            } else {
                // No CloudKit store to probe anymore — the local store
                // opens unconditionally (Pears overlays sync).
                Color.clear
                    .task {
                        storeReady = true
                    }
            }
        }
        .modelContainer(container)
    }
}
extension Notification.Name {
    static let sharedLibraryInviteArrived = Notification.Name("sharedLibraryInviteArrived")
    /// A book was deleted outside LibraryView (e.g. a sibling copy from the
    /// edit form's copy picker); LibraryView adds the id to its deletedIDs
    /// stale-snapshot guard.
    static let bookDeletedExternally = Notification.Name("bookDeletedExternally")
}
