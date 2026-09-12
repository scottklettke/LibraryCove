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

            let share = try await engine.makeShare(title: currentTitle)
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
        let destination = try await bringBooksHomeAndResolveDestination(keepBooks: keepCopy)
        try await SharedLibraryEngine.shared.leaveAsParticipant()
        try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
        Persistence.swapShared(to: destination.container)
        SyncSettings.selectedProvider = destination.kind
        SharedLibrarySettings.previousProvider = nil
    }

    /// Owner stops sharing: everyone loses access to the share. The owner's
    /// data comes home via MERGE (dedup-insert — never wipes the private
    /// store), the destination container is hot-swapped into the running
    /// app, then the zone and share are removed.
    static func stopSharing() async throws {
        let destination = try await bringBooksHomeAndResolveDestination(keepBooks: true)
        try await SharedLibraryEngine.shared.stopSharingAsOwner()
        try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
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

    /// A context on the PRIVATE store for flows that just ended a share and
    /// now operate on fresh/foreign content (delete-all, replace-import).
    @MainActor
    static func privateContextAfterDiscard() throws -> ModelContext {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let configuration = try SyncStoreRegistry.provider(
            for: SyncSettings.selectedProvider
        ).makeStoreConfiguration()
        let container = try ModelContainer(for: schema, configurations: [configuration])
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
        var cloudHasBooks = false
        var cloudContainer: ModelContainer?
        if FileManager.default.fileExists(atPath: cloudStoreURL.path),
           let container = try? ModelContainer(for: schema,
                                               configurations: [ModelConfiguration(schema: nil,
                                                                                    url: cloudStoreURL,
                                                                                    allowsSave: true)]) {
            let cloudContext = ModelContext(container)
            cloudHasBooks = ((try? cloudContext.fetchCount(FetchDescriptor<Book>())) ?? 0) > 0
            cloudContainer = container
        }
        if cloudHasBooks, let cloudContainer {
            return HomeDestination(kind: .iCloud, container: cloudContainer)
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
        if let container = try? ModelContainer(for: schema,
                                               configurations: [ModelConfiguration(schema: nil,
                                                                                   url: storeURL,
                                                                                   allowsSave: true)]) {
            return container
        }
        return Persistence.shared
    }
}
