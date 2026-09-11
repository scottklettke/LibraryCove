import Foundation
import SwiftData

/// Coordinates provider switches.
///
/// Changing provider in Settings snapshots the current library
/// (`SyncSettings.writeSnapshot`) and records the new selection; the switch
/// itself applies on the next launch, when the store is created for the new
/// provider. `finishPendingMigrationIfNeeded` must run at launch to pour that
/// snapshot into the fresh store.
@MainActor
enum SyncCoordinator {
    static func finishPendingMigrationIfNeeded(context: ModelContext) {
        guard SyncSettings.hasPendingSnapshot,
              let data = SyncSettings.readSnapshot() else { return }
        do {
            let summary = try LibraryDataService.importArchive(data: data, context: context)
            // Only drop the snapshot once the target store is in charge, so a
            // failed launch retries safely.
            SyncSettings.clearSnapshot()
            _ = summary
        } catch {
            // Keep the snapshot; a later launch retries the hand-off.
        }
    }
}
