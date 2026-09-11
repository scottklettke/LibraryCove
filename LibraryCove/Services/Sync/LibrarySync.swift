import Foundation
import SwiftData

/// The user-facing choice for how the library store is hosted. Picking one
/// swaps which SwiftData configuration backs the library on the next launch.
/// This is distinct from the per-sync-engine `SyncProvider` protocol
/// (change-log push/pull) in `SyncProvider.swift`.
enum LibrarySync: String, CaseIterable, Identifiable, Codable {
    case localOnly
    case iCloud
    case dropbox
    case box
    case nextcloud
    case sharedLibrary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localOnly: return "Local only"
        case .iCloud: return "iCloud Sync"
        case .sharedLibrary: return "Shared Library"
        case .dropbox: return "Dropbox"
        case .box: return "Box"
        case .nextcloud: return "Nextcloud"
        }
    }

    /// True when the option can be used end-to-end today. Dropbox/Box/Nextcloud
    /// are structural placeholders that register but aren't built out yet.
    var isAvailableNow: Bool {
        switch self {
        case .localOnly, .iCloud, .sharedLibrary: return true
        case .dropbox, .box, .nextcloud: return false
        }
    }
}

/// The contract for backing the library store for a `LibrarySync` option.
/// Local-only and iCloud produce SwiftData configurations; the placeholder
/// cloud providers conform structurally and throw until they're implemented.
protocol SyncStoreProvider {
    var librarySync: LibrarySync { get }
    /// Builds the SwiftData store configuration for this option. Throws when
    /// the option can't back the store (not implemented / missing account).
    func makeStoreConfiguration() throws -> ModelConfiguration
    /// Called once, after the app relaunches onto this option's store.
    func activateStore() async throws
    /// Called when the user switches away from this option.
    func deactivateStore() async
}

/// Registers the concrete store providers behind each `LibrarySync` option.
enum SyncStoreRegistry {
    static func provider(for kind: LibrarySync) -> any SyncStoreProvider {
        switch kind {
        case .localOnly: return SwiftDataLocalOnlySync()
        case .iCloud: return SwiftDataiCloudSync()
        case .sharedLibrary: return SwiftDataSharedLibrarySync()
        case .dropbox: return DropboxSyncStoreProvider()
        case .box: return BoxSyncStoreProvider()
        case .nextcloud: return NextcloudSyncStoreProvider()
        }
    }

    /// Best-effort container for an option. If its store can't be opened (e.g.
    /// no iCloud account / unregistered container), it degrades to a local
    /// store instead of crashing — the app still launches.
    static func makeContainer(for kind: LibrarySync) -> ModelContainer {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        do {
            let configuration = try provider(for: kind).makeStoreConfiguration()
            if kind == .localOnly {
                return try ModelContainer(for: schema, configurations: [configuration])
            }
            return try cloudOrLocal(for: schema, configuration)
        } catch {
            // Provided config failed outright — degrade to local.
            return try! ModelContainer(for: schema,
                                       configurations: [ModelConfiguration(isStoredInMemoryOnly: false)])
        }
    }

    private static func cloudOrLocal(for schema: Schema,
                                     _ configuration: ModelConfiguration) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Cloud store unavailable — fall back to local so data keeps working.
            return try ModelContainer(for: schema,
                                      configurations: [ModelConfiguration(isStoredInMemoryOnly: false)])
        }
    }
}

/// Errors surfaced while activating a library store.
enum LibrarySyncError: LocalizedError, Equatable {
    case notImplementedFor(LibrarySync)

    var errorDescription: String? {
        switch self {
        case .notImplementedFor(let option):
            return "\(option.displayName) sync isn't implemented yet."
        }
    }
}

// MARK: - Implemented store providers

/// The default local store — no syncing, everything on this device.
struct SwiftDataLocalOnlySync: SyncStoreProvider {
    let librarySync: LibrarySync = .localOnly

    func makeStoreConfiguration() throws -> ModelConfiguration {
        ModelConfiguration(isStoredInMemoryOnly: false)
    }

    func activateStore() async throws {}
    func deactivateStore() async {}
}

/// CloudKit-backed store in the app's private iCloud database. SwiftData does
/// the syncing; account state and the store identity come from iCloud.
struct SwiftDataiCloudSync: SyncStoreProvider {
    let librarySync: LibrarySync = .iCloud
    /// Must match the container in `LibraryCove.entitlements` (and be registered
    /// for the signing team in the developer portal).
    static let containerIdentifier = "iCloud.com.librarycove.app"

    func makeStoreConfiguration() throws -> ModelConfiguration {
        // A distinct store file so the cloud store never clobbers (or reuses)
        // the local default.store. Their contents move between the two via the
        // snapshot migration when the user switches providers.
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let url = base.appendingPathComponent("default-cloud.store")
        return ModelConfiguration(schema: nil, url: url, allowsSave: true,
                                  cloudKitDatabase: .private(Self.containerIdentifier))
    }

    func activateStore() async throws {
        // SwiftData CloudKit stores start syncing automatically once loaded.
    }

    func deactivateStore() async {}
}

/// Local mirror store for the shared library. Never touches CloudKit itself —
/// `SharedLibraryEngine` is the only cloud writer/reader. Content moves
/// between this store and the previous provider's store via the same
/// snapshot hand-off the other providers use.
struct SwiftDataSharedLibrarySync: SyncStoreProvider {
    let librarySync: LibrarySync = .sharedLibrary

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("default-shared.store")
    }

    func makeStoreConfiguration() throws -> ModelConfiguration {
        ModelConfiguration(schema: nil, url: Self.storeURL, allowsSave: true)
    }

    func activateStore() async throws {
        // Sync is driven by SharedLibraryEngine.syncNow, called by the app at
        // launch and after share-accept — nothing to start here.
    }

    func deactivateStore() async {}
}

// MARK: - Structural placeholders

/// Shared placeholder behavior for store options that aren't built out yet.
private struct UnavailableSyncStore: SyncStoreProvider {
    let librarySync: LibrarySync

    func makeStoreConfiguration() throws -> ModelConfiguration {
        throw LibrarySyncError.notImplementedFor(librarySync)
    }

    func activateStore() async throws {
        throw LibrarySyncError.notImplementedFor(librarySync)
    }

    func deactivateStore() async {}
}

struct DropboxSyncStoreProvider: SyncStoreProvider {
    let librarySync: LibrarySync = .dropbox
    private let impl = UnavailableSyncStore(librarySync: .dropbox)
    func makeStoreConfiguration() throws -> ModelConfiguration { try impl.makeStoreConfiguration() }
    func activateStore() async throws { try await impl.activateStore() }
    func deactivateStore() async { await impl.deactivateStore() }
}

struct BoxSyncStoreProvider: SyncStoreProvider {
    let librarySync: LibrarySync = .box
    private let impl = UnavailableSyncStore(librarySync: .box)
    func makeStoreConfiguration() throws -> ModelConfiguration { try impl.makeStoreConfiguration() }
    func activateStore() async throws { try await impl.activateStore() }
    func deactivateStore() async { await impl.deactivateStore() }
}

struct NextcloudSyncStoreProvider: SyncStoreProvider {
    let librarySync: LibrarySync = .nextcloud
    private let impl = UnavailableSyncStore(librarySync: .nextcloud)
    func makeStoreConfiguration() throws -> ModelConfiguration { try impl.makeStoreConfiguration() }
    func activateStore() async throws { try await impl.activateStore() }
    func deactivateStore() async { await impl.deactivateStore() }
}
