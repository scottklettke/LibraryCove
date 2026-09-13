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

    /// A container for tests / previews backed entirely by memory.
    static var inMemory: ModelContainer = {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
                Library.self,
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
