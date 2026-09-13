import Foundation
import SwiftData

/// The provider-switch engine, extracted from SettingsView so non-UI flows
/// (restoring a backup made under the other provider) can switch providers
/// with the exact same semantics as the Settings picker.
@MainActor
enum ProviderSwitcher {
    /// Moves the library to `new`'s store: snapshot the live store, merge it
    /// into the target container (never deleteAll — CloudKit-backed targets
    /// would duplicate), carry the active member over, then hot-swap the app
    /// onto the target store and persist the choice. Backups move with the
    /// library (companion mirroring) at the commit point.
    ///
    /// Silent by design: callers surface success however they like (the
    /// Settings picker reflects the change live; the Backups page notes it
    /// next to the restore). Throws when the snapshot or the merge fails —
    /// in that case NOTHING changed (no swap, no provider write, backup
    /// sets untouched).
    static func perform(to new: LibrarySync) async throws {
        guard new.isAvailableNow else {
            throw LibrarySyncError.notImplementedFor(new)
        }
        // Switching INTO the shared mirror is never a picker/restore action:
        // shares are entered and left through the sharing flows only (which
        // manage zone + membership state). A stale list entry tagged
        // .sharedLibrary must not route through here.
        guard new != .sharedLibrary else {
            throw LibrarySyncError.notImplementedFor(new)
        }
        guard new != SyncSettings.selectedProvider else { return }
        // Leaving iCloud right after a bulk change can freeze a polluted
        // snapshot: server-side deletes from that change are still
        // propagating, so the device store may briefly hold rows the server
        // has since removed — copying them into the (never re-synced) local
        // store makes the pollution permanent. Wait out the window.
        if SyncSettings.selectedProvider == .iCloud, SyncSettings.iCloudMayBeConverging {
            throw LibrarySyncError.iCloudStillSyncing
        }

        let liveContext = Persistence.shared.mainContext
        // 1) Snapshot the live library (zip keeps cover files).
        guard let snapshot = await LibraryDataService.export(context: liveContext) else {
            throw LibraryDataError.exportFailed
        }
        // 2) Open the target store and copy the snapshot into it — 1:1,
        // NO dedupe. mergeArchive collapses same-ISBN/same-title copies,
        // which would silently drop the user's duplicate books: a backup
        // taken after the switch (or a later switch back) would be missing
        // them. The snapshot is the authoritative library; copy it as-is.
        let targetContainer = SyncStoreRegistry.makeContainer(for: new)
        try LibraryDataService.copyArchive(data: snapshot,
                                           context: ModelContext(targetContainer))
        // 3) Guarantee an active member in the target store (a CloudKit
        // target may not have mirrored its User rows down yet).
        let targetContext = ModelContext(targetContainer)
        let hasActiveUser = ((try? targetContext.fetchCount(
            FetchDescriptor<User>(predicate: #Predicate { $0.isActive }))) ?? 0) > 0
        if !hasActiveUser {
            let active = ((try? liveContext.fetch(FetchDescriptor<User>(
                predicate: #Predicate { $0.isActive }
            ))) ?? []).first
            if let active {
                targetContext.insert(User(id: active.id,
                                          email: active.email,
                                          displayName: active.displayName,
                                          avatarURL: active.avatarURL,
                                          timezone: active.timezone,
                                          language: active.language,
                                          isActive: true,
                                          createdAt: active.createdAt,
                                          lastLoginAt: active.lastLoginAt))
                try? targetContext.save()
            }
        }
        // 4) Commit: backups move with the library, the choice persists, the
        // app hot-swaps onto the new store (root re-injects via notification).
        BackupStore.mirrorForProviderSwitch(to: new)
        SyncSettings.selectedProvider = new
        SyncSettings.markBulkChange()
        Persistence.swapShared(to: targetContainer)
    }
}
