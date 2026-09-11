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
                return "Couldn't prepare the library switch. Nothing changed."
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
    /// the private store (dedup-insert — never wipes the participant's own
    /// books), then removes the user from the share. Relaunch returns to the
    /// pre-sharing provider.
    static func leave(keepCopy: Bool) async throws {
        if keepCopy {
            try await moveMirrorContentIntoPrivateStore(mode: .merge)
        }
        try await SharedLibraryEngine.shared.leaveAsParticipant()
        SyncSettings.selectedProvider = SharedLibrarySettings.previousProvider ?? .localOnly
        SharedLibrarySettings.previousProvider = nil
        try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
    }

    /// Owner stops sharing: everyone loses access. The owner keeps the data —
    /// the mirror content REPLACES the private store (it is the same library
    /// the owner started with), then relaunch returns to the prior provider.
    static func stopSharing() async throws {
        try await moveMirrorContentIntoPrivateStore(mode: .replace)
        try await SharedLibraryEngine.shared.stopSharingAsOwner()
        SyncSettings.selectedProvider = SharedLibrarySettings.previousProvider ?? .localOnly
        SharedLibrarySettings.previousProvider = nil
        try? FileManager.default.removeItem(at: SwiftDataSharedLibrarySync.storeURL)
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
    }

    private enum CopyMode { case merge, replace }

    /// Moves the mirror store's content into the PRIVATE store container.
    /// Explicitly not `Persistence.shared.mainContext`: while the app runs in
    /// shared-library mode that context IS the mirror, so importing into it
    /// would clobber the source (importArchive delete-alls).
    private static func moveMirrorContentIntoPrivateStore(mode: CopyMode) async throws {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let configuration = try SyncStoreRegistry.provider(
            for: SharedLibrarySettings.previousProvider ?? .localOnly
        ).makeStoreConfiguration()
        let privateContainer = try ModelContainer(for: schema, configurations: [configuration])
        let privateContext = ModelContext(privateContainer)

        let mirrorContext = ModelContext(SwiftDataSharedLibrarySync.containerForMigration())
        guard let data = await LibraryDataService.export(context: mirrorContext) else { return }
        switch mode {
        case .merge:
            try LibraryDataService.mergeArchive(data: data, context: privateContext)
        case .replace:
            try LibraryDataService.importArchive(data: data, context: privateContext)
        }
    }
}

/// Persists the provider to return to when leaving/stopping the share.
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
