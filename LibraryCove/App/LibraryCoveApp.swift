import CloudKit
import SwiftData
import SwiftUI
import UIKit

/// Receives CloudKit share invitations (user tapped a share link while the
/// app was installed). The metadata is stashed; the join itself completes on
/// the next RootView appearance, because joining flips the store provider and
/// the mirror store must exist before syncing starts.
final class ShareAcceptDelegate: NSObject, UIApplicationDelegate {
    /// Routes scene connections to `ShareAcceptSceneDelegate` so the
    /// non-deprecated `windowScene(_:userDidAcceptCloudKitShareWith:)` hook
    /// fires (the UIApplicationDelegate variant is deprecated since iOS 26
    /// and may not be invoked under the SwiftUI scene lifecycle).
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ShareAcceptSceneDelegate.self
        return configuration
    }

    /// Fallback for iOS versions where the app-level callback still fires.
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Self.stash(metadata)
    }

    static func stash(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            SharedLibraryCoordinator.storePendingAcceptIfAny(metadata: metadata)
            NotificationCenter.default.post(name: .sharedLibraryInviteArrived, object: nil)
        }
    }

    /// CloudKit delivers the registry zone's silent subscription through
    /// APNs; forward it so library renames made on one device reach an
    /// already-running app on the other. Content-row mirroring has its own
    /// import path; this only funnels into the registry pull.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if CKNotification(fromRemoteNotificationDictionary: userInfo) != nil {
            Task { @MainActor in
                LibraryScope.shared.pullRegistryFromCloud()
            }
        }
        completionHandler(.noData)
    }
}

/// Scene-level share-accept hook (the supported path since iOS 26).
final class ShareAcceptSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        ShareAcceptDelegate.stash(metadata)
    }
}

@main
struct LibraryCoveApp: App {
    @UIApplicationDelegateAdaptor(ShareAcceptDelegate.self) private var shareAcceptDelegate
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
                Color.clear
                    .task {
                        // A brand-new install on a device without a signed-in
                        // iCloud session opens the CloudKit-backed store by
                        // default (the provider default), and its mirroring
                        // setup throws uncaught exceptions that abort saves —
                        // observed as "library was created but couldn't be
                        // saved" immediately after onboarding. Degrade to the
                        // local store until an iCloud account is actually
                        // available; the provider switch path moves data into
                        // the cloud store once the user signs in.
                        // UI tests skip the accountStatus() probe entirely:
                        // it can stall for the whole test in the XCUITest
                        // sandbox (empty Color.clear window), and offline-
                        // deterministic tests want the local store anyway.
                        // ANY UI_TEST_* env marks a test launch — the
                        // persistence-relaunch test needs the skip without
                        // the reset seam.
                        if SyncSettings.selectedProvider == .iCloud {
                            let isUITest = ProcessInfo.processInfo.environment.keys
                                .contains { $0.hasPrefix("UI_TEST_") }
                            let hasAccount = isUITest ? true
                                : await SharedLibraryEngine.shared.hasICloudAccount()
                            if !hasAccount {
                                Persistence.degradeToLocal()
                                container = Persistence.shared
                            }
                        }
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
