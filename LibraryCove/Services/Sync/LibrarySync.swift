import Foundation
import SwiftData

/// Sync destinations. iCloud Sync and the CKShare shared-library flow
/// are RETIRED — Pears P2P is the only device-sync path (it is not a
/// store provider: it overlays the local store). Kept as a Codable enum
/// so stored preferences decode; every legacy value normalizes to
/// .localOnly on read.
enum LibrarySync: String, CaseIterable, Identifiable, Codable {
    case localOnly
    case iCloud
    case sharedLibrary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localOnly: return "This device (P2P sync available)"
        case .iCloud, .sharedLibrary: return "This device (P2P sync available)"
        }
    }

    /// The effective provider for ANY stored value: everything is the
    /// local store now; PearsSyncEngine overlays sync onto it.
    var normalized: LibrarySync {
        .localOnly
    }

    /// True when the option can be used end-to-end today.
    var isAvailableNow: Bool {
        normalized == .localOnly
    }
}

/// The contract for backing the library store. Only the local provider
/// remains; PearsSyncEngine is not a store provider — it mirrors rows
/// over Hyperdrive while the data lives in the local SwiftData store.
protocol SyncStoreProvider {
    var librarySync: LibrarySync { get }
    func makeStoreConfiguration() throws -> ModelConfiguration
    func activateStore() async throws
    func deactivateStore() async
}

/// Registers the concrete store provider. Everything resolves to the
/// local store; legacy preferences normalize on read.
enum SyncStoreRegistry {
    static func provider(for kind: LibrarySync) -> any SyncStoreProvider {
        SwiftDataLocalOnlySync()
    }

    /// The live container when the requested provider's store IS already
    /// open; else a fresh local container. Kept for the swap/migration
    /// call sites, though only one store exists now.
    static func makeContainer(for kind: LibrarySync) -> ModelContainer {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        if let requested = try? provider(for: kind).makeStoreConfiguration().url,
           requested == Persistence.liveStoreURL {
            return Persistence.shared
        }
        do {
            let configuration = try provider(for: kind).makeStoreConfiguration()
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            return try! ModelContainer(for: schema,
                                       configurations: [// cloudKitDatabase(.none) is load-bearing: with the iCloud entitlement
        // present, SwiftData's .automatic default silently enables
        // NSPersistentCloudKitContainer mirroring on this store — the
        // channel that synced name/deletes between devices after iCloud
        // was "removed". Pears is the only sync path; the local store
        // must never mirror.
        ModelConfiguration(isStoredInMemoryOnly: false,
                           cloudKitDatabase: .none)])
        }
    }
}

// MARK: - Store provider

/// The on-device store — Pears P2P mirrors it to the user's other
/// devices; backups remain user-initiated exports/imports.
struct SwiftDataLocalOnlySync: SyncStoreProvider {
    let librarySync: LibrarySync = .localOnly

    func makeStoreConfiguration() throws -> ModelConfiguration {
        // cloudKitDatabase(.none) is load-bearing: with the iCloud entitlement
        // present, SwiftData's .automatic default silently enables
        // NSPersistentCloudKitContainer mirroring on this store — the
        // channel that synced name/deletes between devices after iCloud
        // was "removed". Pears is the only sync path; the local store
        // must never mirror.
        ModelConfiguration(isStoredInMemoryOnly: false,
                           cloudKitDatabase: .none)
    }

    func activateStore() async throws {}
    func deactivateStore() async {}
}

enum LibrarySyncError: LocalizedError {
    case notImplementedFor(LibrarySync)

    var errorDescription: String? {
        switch self {
        case .notImplementedFor(let option):
            return "\(option.displayName) sync isn't available."
        }
    }
}
