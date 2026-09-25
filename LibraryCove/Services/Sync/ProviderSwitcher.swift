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
        // Local Only is retired as a user-selectable mode: its store shares
        // the CloudKit zone's history, so switching back to iCloud re-pulls
        // server rows and duplicates the library. Keep iCloud as the only
        // switch target (the localOnly case remains for the internal
        // fallback container and legacy data).
        guard new != .localOnly else {
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
        // An EMPTY library is exempt: there is nothing to snapshot, so no
        // pollution can be frozen — blocking would be pure friction.
        let liveContext = Persistence.shared.mainContext
        let bookCount = (try? liveContext.fetchCount(FetchDescriptor<Book>())) ?? 0
        if bookCount > 0,
           SyncSettings.selectedProvider == .iCloud,
           SyncSettings.iCloudMayBeConverging {
            throw LibrarySyncError.iCloudStillSyncing
        }

        // 1) Snapshot the live library (zip keeps cover files).
        guard let snapshot = await LibraryDataService.export(context: liveContext) else {
            throw LibraryDataError.exportFailed
        }
        // 2) Open the target store and MIGRATE it to the snapshot: 1:1 copy
        // (no ISBN/title dedupe — duplicate copies survive) PLUS targeted
        // deletes of target rows the snapshot doesn't contain. Union-style
        // copying made the target ACCUMULATE stale rows across switch round
        // trips (the doubling bug); the snapshot is authoritative.
        let targetContainer = SyncStoreRegistry.makeContainer(for: new)
        try LibraryDataService.migrateArchive(data: snapshot,
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
        // 4) Commit: the choice persists, the app hot-swaps onto the new
        // store (root re-injects via notification). Backups live in the
        // iCloud container and need no per-provider mirroring.
        SyncSettings.selectedProvider = new
        SyncSettings.markBulkChange()
        Persistence.swapShared(to: targetContainer)
    }
}
