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
            // COPY 1:1 (copyArchive), not mergeArchive: the snapshot IS the
            // owner's authoritative library (beginShare snapshots their own
            // content before the mirror store exists) — merge-dedupe would
            // collapse their duplicate copies when entering the share, the
            // same loss class fixed for provider switching in 6951982.
            // copyArchive skips book ids already present, so a re-pour
            // after a crash mid-pour is idempotent; existing CloudKit rows
            // are left alone (no deleteAll → no re-flood).
            let summary = try LibraryDataService.copyArchive(data: data, context: context)
            // Only drop the snapshot once the target store is in charge, so a
            // failed launch retries safely.
            SyncSettings.clearSnapshot()
            _ = summary
        } catch {
            // Keep the snapshot; a later launch retries the hand-off.
        }
    }
}
