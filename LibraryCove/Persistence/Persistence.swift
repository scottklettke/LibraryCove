import Foundation
import SwiftData

/// Central persistence layer for LibraryCove.
/// Registers all SwiftData @Model types and exposes the shared container.
///
/// The backing store depends on the selected sync provider (`SyncSettings`):
/// iCloud (CloudKit) by default, local-only when chosen. Provider switches
/// hot-swap the container in place — `swapShared(to:)` replaces the container
/// and posts `.syncStoreSwapped`, which the app root observes to re-inject
/// the new container into the view tree. No restart needed.
enum Persistence {
    /// Notification posted after `shared` has been replaced. The app root
    /// listens and re-injects the container into the view tree.
    static let storeSwappedNotification = Notification.Name("syncStoreSwapped")

    private static var _shared: ModelContainer =
        SyncStoreRegistry.makeContainer(for: SyncSettings.selectedProvider)

    /// The shared on-device ModelContainer (local or CloudKit-backed).
    static var shared: ModelContainer {
        _shared
    }

    /// Replaces the live container. Call after the new store's content is
    /// fully in place; SwiftUI re-injects via `.syncStoreSwapped`.
    static func swapShared(to container: ModelContainer) {
        _shared = container
        NotificationCenter.default.post(name: storeSwappedNotification, object: nil)
    }

    /// Replaces the shared container with a plain local (non-CloudKit)
    /// store. Used when the device has no iCloud session: the CloudKit
    /// mirroring of the iCloud store throws uncaught exceptions in that
    /// state, which abort saves (observed as "library couldn't be saved"
    /// on fresh installs). The provider preference is untouched — when an
    /// iCloud account becomes available, relaunching (or the switch flow)
    /// opens the cloud store again.
    static func degradeToLocal() {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let url = base.appendingPathComponent("default-nocloud.store")
        if let container = try? ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: nil, url: url, allowsSave: true)]
        ) {
            _shared = container
            NotificationCenter.default.post(name: storeSwappedNotification, object: nil)
        }
    }

    /// A container for tests / previews backed entirely by memory.
    static var inMemory: ModelContainer = {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create in-memory ModelContainer: \(error)")
        }
    }()
}
