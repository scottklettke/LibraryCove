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
    let container: ModelContainer

    init() {
        container = Persistence.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
