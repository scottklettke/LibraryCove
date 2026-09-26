import CloudKit
import SwiftData
import SwiftUI

/// Orchestrates every shared-library flow that spans UI, CloudKit, and the
/// store switch: becoming owner (snapshot → mirror → share), joining from an
/// invitation, leaving with "keep a copy", and the owner stopping the share.
///
/// Store-switch rule (agreed design): entering or leaving the shared library
/// always follows the provider-switch pattern — snapshot the current library,
/// flip `SyncSettings.selectedProvider`, relaunch. Participants do NOT seed
/// their mirror from the snapshot (their private books must not enter the
/// shared zone); only the owner's switch seeds the mirror.
@MainActor
enum SharedLibraryCoordinator {
    enum FlowError: LocalizedError {
        case snapshotFailed

        var errorDescription: String? {
            switch self {
            case .snapshotFailed:
                return "Stopping was blocked because neither the shared library nor your private library contains any books. If you expected books here, check Settings → Data → Export library, and report this via the feedback link — this state shouldn't be reachable."
            }
        }
    }

    // MARK: - Becoming owner

    /// Creates the share from the current library. Order matters:
    /// 1. snapshot the active store's content (so nothing is lost),
    /// 2. select `.sharedLibrary` — on relaunch the snapshot is poured into
    ///    the mirror store by the standard migration,
    /// 3. create the CloudKit zone + share NOW (metadata persists even though
    ///    the app restarts afterwards).
    /// The initial record upload happens after relaunch, once the mirror store
    /// exists and `syncNow` pushes every record as "dirty".
    /// Returns the share for the sharing sheet.
    static func beginShare(currentTitle: String) async throws -> CKShare {
        guard let libraryID = LibraryScope.shared.activeID(context: Persistence.shared.mainContext) else {
            throw SharedLibraryError.noActiveLibrary
        }
        return try await beginShare(currentTitle: currentTitle, libraryID: libraryID)
    }

    /// Per-library variant: creates the share for a SPECIFIC library under
    /// its own namespace (zone, share record, membership state). The
    /// snapshot-pour + provider flip still applies to the ACTIVE library —
    /// sharing a library makes it the active one so its content syncs.
    static func beginShare(currentTitle: String, libraryID: String) async throws -> CKShare {
        // Guests are view-only: they cannot create the share or its links.
        // Editors and admins can. (Owner passes: membership .owner => admin.)
        guard SharedLibraryEngine.shared.myRole(libraryID: libraryID) != .guest else {
            throw SharedLibraryError.notPermitted
        }
        let engine = SharedLibraryEngine.shared
        guard await engine.hasICloudAccount() else { throw SharedLibraryError.noICloudAccount }

        // Remember where to go back to on leave/stop (persisted before the
        // provider flips, so the relaunch handles everything else).
        SyncLibraryHandoff.rememberPreviousProvider()

        do {
            // Snapshot the active store's content — on relaunch the standard
            // migration pours it into the fresh mirror store.
            guard let snapshot = await LibraryDataService.export(context: Persistence.shared.mainContext) else {
                throw FlowError.snapshotFailed
            }
            guard SyncSettings.writeSnapshot(snapshot) else { throw FlowError.snapshotFailed }

            let share = try await engine.makeShare(title: currentTitle, libraryID: libraryID)
            SyncSettings.selectedProvider = .sharedLibrary
            return share
        } catch {
            // A failed share creation must not strand the migration snapshot:
            // the next provider switch would pour it into the store as if a
            // switch had been requested.
            SyncSettings.clearSnapshot()
            throw error
        }
    }

    // MARK: - Joining

    /// Processes accepted share metadata: joins the share now and schedules
    /// the provider switch so the next launch opens the mirror store, which
    /// then pulls the owner's zone. The joiner's own library is untouched.
    static func join(with metadata: CKShare.Metadata) async throws {
        let engine = SharedLibraryEngine.shared
        try await engine.accept(metadata: metadata)
        SyncLibraryHandoff.rememberPreviousProvider()
        // Joining over an existing membership: the old mirror content must
        // not bleed into the new share's library.
        if SharedLibrarySettings.membership != .none {
            try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
            SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
        }
        SyncSettings.selectedProvider = .sharedLibrary
        SharedLibrarySettings.pendingAcceptMetadata = nil
    }

    /// True when CloudKit handed us an invitation while we weren't in the
    /// sharing flow — surfaced as a prompt at the next launch.
    static func storePendingAcceptIfAny(metadata: CKShare.Metadata) {
        guard SharedLibrarySettings.membership != .owner else { return }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: metadata,
                                                        requiringSecureCoding: true) {
            SharedLibrarySettings.pendingAcceptMetadata = data
        }
    }

    /// Launch-time hook: joins from a pending invitation, if any.
    static func processPendingAcceptIfNeeded() async {
        guard let data = SharedLibrarySettings.pendingAcceptMetadata,
              let metadata = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKShare.Metadata.self,
                                                                     from: data) else { return }
        do {
            try await join(with: metadata)
        } catch {
            SharedLibraryEngine.shared.reportError(error.localizedDescription)
        }
    }

    // MARK: - Leaving / stopping

    /// Participant leaves. `keepCopy` first MERGES the mirror content into
    /// the destination private store (dedup-insert — never wipes the
    /// participant's own books), then removes the user from the share. The
    /// destination container is hot-swapped into the running app — no
    /// restart needed.
    static func leave(keepCopy: Bool) async throws {
        guard let libraryID = LibraryScope.shared.activeID(context: Persistence.shared.mainContext) else {
            throw SharedLibraryError.noActiveLibrary
        }
        let destination = try await bringBooksHomeAndResolveDestination(keepBooks: keepCopy)
        try await SharedLibraryEngine.shared.leaveAsParticipant()
        try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
        SharedLibrarySettings.setMembership(.none, libraryID: libraryID)
        Persistence.swapShared(to: destination.container)
        SyncSettings.selectedProvider = destination.kind
        SharedLibrarySettings.previousProvider = nil
    }

    /// Owner stops sharing: everyone loses access to the share. The owner's
    /// data comes home via MERGE (dedup-insert — never wipes the private
    /// store), the destination container is hot-swapped into the running
    /// app, then the zone and share are removed.
    static func stopSharing() async throws {
        guard let libraryID = LibraryScope.shared.activeID(context: Persistence.shared.mainContext) else {
            throw SharedLibraryError.noActiveLibrary
        }
        // Only admins may stop sharing (owner or promoted admin): editors
        // can edit and share links but cannot turn the share off. Reads the
        // PER-LIBRARY record name — the legacy global key is nil under the
        // per-library model and would silently fall back to "owner",
        // letting any participant through. An owner has no participant
        // record of their own and passes via membership.
        let selfRecordName = SharedLibrarySettings.currentUserRecordName(libraryID: libraryID)
        if SharedLibrarySettings.membership(libraryID: libraryID) != .owner {
            guard let selfRecordName,
                  ShareRoleStore.role(libraryID: libraryID,
                                      participantRecordName: selfRecordName) == .admin
            else {
                throw SharedLibraryError.notPermitted
            }
        }
        let destination = try await bringBooksHomeAndResolveDestination(keepBooks: true)
        // Per-library shares: the GLOBAL stopSharingAsOwner reads the legacy
        // global ownerZoneID (nil under the per-library model) — no zone
        // would be deleted and participants would keep access. Always tear
        // down the ACTIVE library's share.
        try await SharedLibraryEngine.shared.stopSharingAsOwner(libraryID: libraryID)
        try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
        SharedLibrarySettings.setMembership(.none, libraryID: libraryID)
        Persistence.swapShared(to: destination.container)
        SyncSettings.selectedProvider = destination.kind
        SharedLibrarySettings.previousProvider = nil
    }

    /// Tears the share down WITHOUT bringing any content home — for flows
    /// that deliberately discard the shared library's contents ("Delete all
    /// data", a replace-import that will install different content). Removes
    /// the zone/share, resets membership, discards the mirror store, and
    /// points the provider at the pre-share provider (or iCloud when
    /// unknown). The caller then operates on a fresh private context.
    static func discardSharedContent() async throws {
        switch SharedLibraryMembershipGate.membership {
        case .owner:
            try await SharedLibraryEngine.shared.stopSharingAsOwner()
        case .participant:
            try await SharedLibraryEngine.shared.leaveAsParticipant()
        case .none:
            break
        }
        SyncSettings.selectedProvider = SharedLibrarySettings.previousProvider ?? .iCloud
        SharedLibrarySettings.previousProvider = nil
        try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
    }

    /// Factory-reset variant of `discardSharedContent`: tears down EVERY
    /// library's share, not just the legacy-gated one. The gate reads only
    /// the pre-migration global keys, so per-library shares are invisible
    /// to it; this iterates `sharedLibraryIDs` instead. CloudKit failures
    /// (no account, offline) never block the reset — that library's keys
    /// are cleared anyway so nothing can re-attach. Best-effort by design:
    /// a participant migrated from legacy state has no per-library accepted
    /// zone (`migrateLegacyShare` drops it), so the remote
    /// removeParticipant is skipped — the local keys still clear. The
    /// epilogue MUST run before the caller's final `sharedLibrary.*` key
    /// sweep: the provider flip reads `previousProvider` (itself a
    /// `sharedLibrary.` key), and the caller wipes whichever store the
    /// flip selects.
    static func discardAllSharedContent() async {
        // No account → CloudKit calls would hang through network timeouts
        // and fail anyway; skip straight to the local key clears. UI-test
        // launches skip the probe entirely: accountStatus() can stall for
        // the whole test in the XCUITest sandbox (the same stall the app
        // root's degrade check skips), and offline-deterministic tests
        // want the pure-local clears anyway.
        let isUITest = ProcessInfo.processInfo.environment.keys
            .contains { $0.hasPrefix("UI_TEST_") }
        let hasAccount = isUITest ? false
            : await SharedLibraryEngine.shared.hasICloudAccount()
        for libraryID in SharedLibrarySettings.sharedLibraryIDs {
            guard hasAccount else {
                SharedLibrarySettings.reset(libraryID: libraryID)
                continue
            }
            do {
                switch SharedLibrarySettings.membership(libraryID: libraryID) {
                case .owner:
                    try await SharedLibraryEngine.shared.stopSharingAsOwner(libraryID: libraryID)
                case .participant:
                    try await SharedLibraryEngine.shared.leaveAsParticipant(libraryID: libraryID)
                case .none:
                    break
                }
            } catch {
                // Unreachable CloudKit must not keep the share state alive.
                SharedLibrarySettings.reset(libraryID: libraryID)
            }
        }
        // Legacy single-share state on a device that has not migrated yet.
        do {
            switch SharedLibraryMembershipGate.membership {
            case .owner:
                try await SharedLibraryEngine.shared.stopSharingAsOwner()
            case .participant:
                try await SharedLibraryEngine.shared.leaveAsParticipant()
            case .none:
                break
            }
        } catch {
            SharedLibrarySettings.reset()
        }
        // Sweep the legacy namespace even when the gate saw .none: the
        // engine paths reset() themselves, but a .none observation (share
        // torn down earlier, or the keys migrated away mid-flow) would
        // otherwise leave legacy leftovers (shareTitle, tokens) behind —
        // a factory reset must leave nothing.
        SharedLibrarySettings.reset()
        SyncSettings.selectedProvider = SharedLibrarySettings.previousProvider ?? .iCloud
        SharedLibrarySettings.previousProvider = nil
        try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())

        // Belt and braces: the per-library teardown above relies on
        // per-library UserDefaults keys to know which zone to delete. A
        // wiped device may have no keys (membership cleared, or CloudKit
        // failed mid-wipe) while the OWNER zone still sits in the private
        // DB holding every pre-wipe book — NSPersistentCloudKitContainer
        // then re-downloads them on the next launch and the registry
        // re-synthesizes old libraries. Enumerate the private DB and
        // delete every zone whose name stems from THIS app's share zone
        // (fixed base name + "-<hash>"), owner or not.
        if hasAccount {
            do {
                let database = SharedLibraryEngine.shared.container.privateCloudDatabase
                let zones = try await database.allRecordZones()
                let ours = zones.filter { zone in
                    zone.zoneID.zoneName == SharedLibraryEngine.zoneName
                        || zone.zoneID.zoneName.hasPrefix(SharedLibraryEngine.zoneName + "-")
                }
                if !ours.isEmpty {
                    let result = try await database.modifyRecordZones(
                        saving: [], deleting: ours.map(\.zoneID))
                    let failures = result.deleteResults.values.compactMap {
                        if case .failure(let e) = $0 { return e } else { return nil }
                    }
                    if !failures.isEmpty {
                        SharedLibraryEngine.shared.reportError(
                            "Reset zone sweep had failures: \(failures)")
                    }
                }
            } catch {
                // Unreachable CloudKit must not block the reset; the wipe
                // marker in the registry zone still carries the cutoff.
                SharedLibraryEngine.shared.reportError(
                    "Reset zone sweep failed: \(error)")
            }
        }
    }

    /// A context on the PRIVATE store for flows that just ended a share and
    /// now operate on fresh/foreign content (delete-all, replace-import).
    @MainActor
    static func privateContextAfterDiscard() throws -> ModelContext {
        // Route through the registry: when the selected provider's store is
        // already open (in-session share), this REUSES the live container
        // instead of opening a second one on the same file.
        let container = SyncStoreRegistry.makeContainer(for: SyncSettings.selectedProvider)
        // Hot-swap: the UI must render this (post-discard) store now, not
        // the removed mirror.
        Persistence.swapShared(to: container)
        return ModelContext(container)
    }

    /// The store books come home to: a fresh container on the destination
    /// provider, plus the provider kind for the settings flip.
    struct HomeDestination {
        let kind: LibrarySync
        let container: ModelContainer
    }

    /// Resolves where books go after a share ends.
    ///   - remembered previousProvider → that provider (normal path);
    ///   - unknown + iCloud-backed store holds books → .iCloud (the user's
    ///     home is the cloud store);
    ///   - unknown + no cloud data → .localOnly (books are in the local
    ///     store).
    private static func resolveDestination() -> HomeDestination {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        if let remembered = SharedLibrarySettings.previousProvider {
            let container = SyncStoreRegistry.makeContainer(for: remembered)
            return HomeDestination(kind: remembered, container: container)
        }
        // Unknown destination: inspect the iCloud-backed store for data.
        let cloudStoreURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first!
            .appendingPathComponent("default-cloud.store")
        if Persistence.liveStoreURL == cloudStoreURL {
            // The cloud store is already open (in-session share with no
            // relaunch). NEVER probe-open a second container on the same
            // file — CloudKit mirroring breaks ("CKScheduler activity
            // identifier already registered").
            let cloudContext = ModelContext(Persistence.shared)
            if ((try? cloudContext.fetchCount(FetchDescriptor<Book>())) ?? 0) > 0 {
                return HomeDestination(kind: .iCloud, container: Persistence.shared)
            }
        } else if FileManager.default.fileExists(atPath: cloudStoreURL.path),
                  let container = try? ModelContainer(for: schema,
                                                      configurations: [ModelConfiguration(schema: nil,
                                                                                           url: cloudStoreURL,
                                                                                           allowsSave: true)]) {
            let cloudContext = ModelContext(container)
            if ((try? cloudContext.fetchCount(FetchDescriptor<Book>())) ?? 0) > 0 {
                return HomeDestination(kind: .iCloud, container: container)
            }
        }
        return HomeDestination(kind: .localOnly,
                               container: SyncStoreRegistry.makeContainer(for: .localOnly))
    }

    /// Merges the mirror store's content into the destination private store
    /// (when the mirror has books) and returns the resolved destination.
    /// Fail-safes:
    ///   - mirror export fails → abort (share stays; nothing destroyed).
    ///   - mirror empty → no copy (merge of nothing is a no-op; teardown
    ///     proceeds so the user is never stuck in a share they want to
    ///     leave — including legitimately empty libraries).
    private static func bringBooksHomeAndResolveDestination(keepBooks: Bool) async throws -> HomeDestination {
        let destination = resolveDestination()
        guard keepBooks else {
            // Deliberate discard (delete-all): destination container is
            // returned empty; the caller clears it.
            return destination
        }

        let mirrorContext = ModelContext(SwiftDataSharedLibrarySync.containerForMigration())
        guard let data = await LibraryDataService.export(context: mirrorContext) else {
            throw FlowError.snapshotFailed
        }
        let summary = try LibraryDataService.previewArchive(data: data)
        // An empty mirror is fine: with merge semantics, stopping a share of
        // an empty library (or one whose books are already home) is a no-op
        // copy followed by teardown — nothing can be lost, so the user is
        // never stuck in a share they want to leave. Only a FAILED EXPORT
        // aborts the flow.
        if summary.books > 0 {
            try LibraryDataService.mergeArchive(data: data, context: destination.container.mainContext)
        }
        return destination
    }

    /// Swaps the destination container into the running app after a share
    /// ends, so the UI reads the private store immediately.
    @MainActor
    static func adoptDestination(_ destination: HomeDestination) {
        Persistence.swapShared(to: destination.container)
        SyncSettings.selectedProvider = destination.kind
        SharedLibrarySettings.previousProvider = nil
    }
}

extension SharedLibraryCoordinator {
    /// Cleans up ORPHANED sharing state: membership is recorded but the app
    /// is no longer running on the shared-library provider (e.g. the user
    /// switched providers in an older build, before switch-away warned and
    /// tore the share down). Without this, Settings shows Share Library
    /// controls under Local only.
    ///
    /// Best-effort cloud cleanup first (owner: revoke the zone/share;
    /// participant: remove self from the share), then clear all local
    /// sharing state. Runs at launch and ignores cloud failures — the local
    /// state must be consistent with the provider regardless.
    static func repairOrphanedMembershipIfNeeded() async {
        guard SyncSettings.selectedProvider != .sharedLibrary,
              SharedLibrarySettings.membership != .none else { return }
        switch SharedLibraryMembershipGate.membership {
        case .owner:
            try? await SharedLibraryEngine.shared.stopSharingAsOwner()
        case .participant:
            try? await SharedLibraryEngine.shared.leaveAsParticipant()
        case .none:
            break
        }
        SharedLibrarySettings.reset()
    }

    /// Deactivates duplicate ACTIVE members: CloudKit stores can hold older
    /// identity records, and mirroring delivers them alongside the current
    /// one — multiple isActive rows make "first(where: \.isActive)"
    /// nondeterministic across views. The newest row (by lastLoginAt, then
    /// createdAt) stays active; the rest are marked inactive (never
    /// deleted — they may hold "Added by" history).
    static func repairDuplicateActiveMembersIfNeeded(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<User>())) ?? []
        let active = all.filter(\.isActive)
        guard active.count > 1 else { return }
        let sorted = active.sorted { lhs, rhs in
            let l = lhs.lastLoginAt ?? lhs.createdAt
            let r = rhs.lastLoginAt ?? rhs.createdAt
            return l > r
        }
        for stale in sorted.dropFirst() {
            stale.isActive = false
        }
        try? context.save()
    }
}

enum SyncLibraryHandoff {
    private static let key = "sharedLibrary.previousProvider"

    /// Call BEFORE flipping `SyncSettings.selectedProvider` to `.sharedLibrary`.
    static func rememberPreviousProvider() {
        let current = SyncSettings.selectedProvider
        guard current != .sharedLibrary else { return }
        UserDefaults.standard.set(current.rawValue, forKey: key)
    }

    static var stored: LibrarySync? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let kind = LibrarySync(rawValue: raw) else { return nil }
        return kind
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

extension SharedLibrarySettings {
    /// Provider the app ran before entering the shared library.
    static var previousProvider: LibrarySync? {
        get { SyncLibraryHandoff.stored }
        set { newValue == nil ? SyncLibraryHandoff.clear() : UserDefaults.standard.set(newValue!.rawValue, forKey: "sharedLibrary.previousProvider") }
    }
}

extension SwiftDataSharedLibrarySync {
    /// A context on the mirror store for migration reads. The app may be
    /// running on a different provider at that moment (leaving happens from
    /// Settings, before the relaunch).
    @MainActor
    static func containerForMigration() -> ModelContainer {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        // While running on .sharedLibrary, the mirror store is the LIVE
        // container (syncNow writes through the app's injected context) —
        // never open a second container on the same file.
        if let liveURL = Persistence.liveStoreURL, liveURL == storeURL {
            return Persistence.shared
        }
        if let container = try? ModelContainer(for: schema,
                                               configurations: [ModelConfiguration(schema: nil,
                                                                                    url: storeURL,
                                                                                    allowsSave: true)]) {
            return container
        }
        return Persistence.shared
    }
}
