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

    private static var _shared: ModelContainer?
    /// Recursive: a guard match in `SyncStoreRegistry.makeContainer`
    /// returns `shared` while `shared` itself is on the stack (same
    /// thread) — a plain NSLock would deadlock.
    private static let _sharedLock = NSRecursiveLock()

    /// The shared on-device ModelContainer (local or CloudKit-backed).
    /// Backed lazily so the registry's reuse guard can ask whether a live
    /// container exists without forcing one open. First-touch init is
    /// lock-serialized: two threads racing here would each open a container
    /// on the SAME store file — the exact double-open this module forbids.
    static var shared: ModelContainer {
        _sharedLock.lock()
        defer { _sharedLock.unlock() }
        if let _shared { return _shared }
        let container = SyncStoreRegistry.makeContainer(for: SyncSettings.selectedProvider)
        _shared = container
        return container
    }

    /// Store URL of the live container, if one is open. Derived from the
    /// container itself (no tracked state), so it stays correct across every
    /// swap/degrade site. `nil` while no container is open (or when the
    /// live store is in-memory, e.g. tests/previews).
    static var liveStoreURL: URL? {
        _sharedLock.lock()
        defer { _sharedLock.unlock() }
        return _shared?.configurations.first { !$0.isStoredInMemoryOnly }?.url
    }

    /// Replaces the live container. Call after the new store's content is
    /// fully in place; SwiftUI re-injects via `.syncStoreSwapped`.
    static func swapShared(to container: ModelContainer) {
        _sharedLock.lock()
        _shared = container
        _sharedLock.unlock()
        // Posted OUTSIDE the lock: synchronous observers read
        // Persistence.shared, which re-enters this lock.
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
            _sharedLock.lock()
            _shared = container
            _sharedLock.unlock()
            // Posted OUTSIDE the lock — same re-entry reason as swapShared.
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
