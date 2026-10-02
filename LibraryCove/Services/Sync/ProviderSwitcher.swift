import Foundation
import SwiftData

/// RETIRED: there is only one store now. The switch engine existed to
/// move data between the local and CloudKit-backed stores; with iCloud
/// sync and CKShare sharing gone, every call site resolves to the local
/// store and the operation is a no-op. Backup restore still uses
/// LibraryDataService.mergeArchive directly.
@MainActor
enum ProviderSwitcher {
    static func perform(to new: LibrarySync) async throws {
        guard new.isAvailableNow else {
            throw LibrarySyncError.notImplementedFor(new)
        }
        // Nothing to do: the local store is the only store, and Pears
        // sync overlays it without changing store files.
    }
}
