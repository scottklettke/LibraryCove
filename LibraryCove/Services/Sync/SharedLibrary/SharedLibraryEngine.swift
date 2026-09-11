import CloudKit
import Foundation
import SwiftData
import SwiftUI

/// Membership state persisted in UserDefaults. Drives which store the app
/// opens at launch (`SyncStoreRegistry`) and what the Settings screen shows.
enum SharedLibraryMembership: String, Codable {
    /// Not part of any share (default).
    case none
    /// This device owns the shared library (created the share).
    case owner
    /// This device joined someone else's shared library.
    case participant
}

/// Persisted facts about the shared library: membership role, CloudKit
/// identifiers needed to reach the zone again, and the last-synced state.
/// `SyncSettings` analog for the sharing feature.
enum SharedLibrarySettings {
    private static let d = UserDefaults.standard

    private enum Key {
        static let membership = "sharedLibrary.membership"
        static let ownerZoneName = "sharedLibrary.ownerZoneName"
        static let ownerZoneOwnerName = "sharedLibrary.ownerZoneOwnerName"
        static let ownerShareRecordName = "sharedLibrary.ownerShareRecordName"
        static let shareURL = "sharedLibrary.shareURL"
        static let shareTitle = "sharedLibrary.shareTitle"
        static let acceptedZoneName = "sharedLibrary.acceptedZoneName"
        static let acceptedZoneOwnerName = "sharedLibrary.acceptedZoneOwnerName"
        static let changeToken = "sharedLibrary.changeToken"
        static let pendingAcceptMetadata = "sharedLibrary.pendingAcceptMetadata"
        static let lastSyncAt = "sharedLibrary.lastSyncAt"
    }

    static var membership: SharedLibraryMembership {
        get { SharedLibraryMembership(rawValue: d.string(forKey: Key.membership) ?? "") ?? .none }
        set { d.set(newValue.rawValue, forKey: Key.membership) }
    }

    /// Owner side: the custom zone the whole shared library lives in.
    static var ownerZoneName: String? {
        get { d.string(forKey: Key.ownerZoneName) }
        set { d.set(newValue, forKey: Key.ownerZoneName) }
    }

    /// `CKRecordZone.ID.ownerName` of the owner zone (the owner's user record
    /// name) — needed to reconstruct the zone ID at launch.
    static var ownerZoneOwnerName: String? {
        get { d.string(forKey: Key.ownerZoneOwnerName) }
        set { d.set(newValue, forKey: Key.ownerZoneOwnerName) }
    }

    /// Owner side: record name of the CKShare record, refetched on demand.
    static var ownerShareRecordName: String? {
        get { d.string(forKey: Key.ownerShareRecordName) }
        set { d.set(newValue, forKey: Key.ownerShareRecordName) }
    }

    /// Owner side: the share URL once CloudKit assigns it (persisted so the
    /// user can re-share without recreating the share).
    static var shareURL: URL? {
        get { d.url(forKey: Key.shareURL) }
        set { d.set(newValue, forKey: Key.shareURL) }
    }

    /// Display name of the shared library shown in UI.
    static var shareTitle: String? {
        get { d.string(forKey: Key.shareTitle) }
        set { d.set(newValue, forKey: Key.shareTitle) }
    }

    /// Participant side: zone ID components of the accepted share's zone.
    static var acceptedZoneName: String? {
        get { d.string(forKey: Key.acceptedZoneName) }
        set { d.set(newValue, forKey: Key.acceptedZoneName) }
    }

    static var acceptedZoneOwnerName: String? {
        get { d.string(forKey: Key.acceptedZoneOwnerName) }
        set { d.set(newValue, forKey: Key.acceptedZoneOwnerName) }
    }

    /// Opaque server change token for the shared zone (both roles). `nil`
    /// means "full fetch next time".
    static var changeTokenData: Data? {
        get { d.data(forKey: Key.changeToken) }
        set { d.set(newValue, forKey: Key.changeToken) }
    }

    /// Raw `CKShare.Metadata` payload accepted but not yet processed (device
    /// joined via link while the app was cold-launched — the mirror store must
    /// exist first, so the join finishes on the next launch).
    static var pendingAcceptMetadata: Data? {
        get { d.data(forKey: Key.pendingAcceptMetadata) }
        set { d.set(newValue, forKey: Key.pendingAcceptMetadata) }
    }

    static var lastSyncAt: Date? {
        get { d.object(forKey: Key.lastSyncAt) as? Date }
        set { d.set(newValue, forKey: Key.lastSyncAt) }
    }

    /// Every trace of sharing on this device (leave/stop-sharing/reset).
    static func reset() {
        for key in [Key.membership, Key.ownerZoneName, Key.ownerZoneOwnerName,
                    Key.ownerShareRecordName, Key.shareURL, Key.shareTitle,
                    Key.acceptedZoneName, Key.acceptedZoneOwnerName,
                    Key.changeToken, Key.pendingAcceptMetadata, Key.lastSyncAt] {
            d.removeObject(forKey: key)
        }
    }

    // MARK: - Derived

    static var ownerZoneID: CKRecordZone.ID? {
        guard let name = ownerZoneName else { return nil }
        return CKRecordZone.ID(zoneName: name, ownerName: ownerZoneOwnerName ?? CKCurrentUserDefaultName)
    }

    static var acceptedZoneID: CKRecordZone.ID? {
        guard let name = acceptedZoneName, let owner = acceptedZoneOwnerName else { return nil }
        return CKRecordZone.ID(zoneName: name, ownerName: owner)
    }

    /// The zone this device syncs against, whatever the role.
    static var activeZoneID: CKRecordZone.ID? {
        switch membership {
        case .owner: return ownerZoneID
        case .participant: return acceptedZoneID
        case .none: return nil
        }
    }
}

/// A participant shown in the Settings "people with access" list.
struct SharedLibraryMember: Identifiable, Equatable {
    var id: String            // participant user record name or stable placeholder
    var name: String
    var isOwner: Bool
    var isCurrentUser: Bool
    var acceptanceStatusDescription: String
    var permissionDescription: String
}

enum SharedLibraryError: LocalizedError {
    case noICloudAccount
    case notShared
    case metadataUnavailable
    case zoneNotFound

    var errorDescription: String? {
        switch self {
        case .noICloudAccount: return "Sign in to iCloud to use a shared library."
        case .notShared: return "This library isn't shared yet."
        case .metadataUnavailable: return "Couldn't read the share invitation details."
        case .zoneNotFound: return "The shared library is no longer available."
        }
    }
}

/// The CloudKit engine behind "Share Library": owns the shared record zone,
/// the `CKShare`, pushes local mirror edits up, pulls remote changes down.
///
/// Architecture (agreed design): while a shared library is active the app runs
/// a local mirror store (`LibrarySync.sharedLibrary`); this engine is the only
/// writer to the cloud zone, so exactly one sync system is in play per store.
///
/// Database split: the owner creates and stores records in its **private**
/// database's custom zone; participants read/write the same zone through the
/// **shared** database. Every operation picks the right database via `db`.
@MainActor
final class SharedLibraryEngine: ObservableObject {
    static let shared = SharedLibraryEngine()

    /// Custom-zone name for the shared library. Fixed so a participant can
    /// find the accepted zone by name inside the shared database (CKShare
    /// doesn't expose its zone ID on the participant side).
    static let zoneName = "LibraryCoveSharedLibrary"

    /// Published so Settings can react without polling.
    @Published private(set) var members: [SharedLibraryMember] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?

    /// Fired after remote changes were applied to the mirror store, so UI can
    /// refresh derived state (counts, shelves, etc.).
    var onRemoteChange: (() -> Void)?

    let container: CKContainer
    private var syncTask: Task<Void, Never>?

    init(container: CKContainer = CKContainer(identifier: SwiftDataiCloudSync.containerIdentifier)) {
        self.container = container
    }

    /// The database this role talks to for the shared zone.
    private var db: CKDatabase {
        SharedLibrarySettings.membership == .owner
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
    }

    // MARK: - Account

    func hasICloudAccount() async -> Bool {
        let status = (try? await container.accountStatus()) ?? .couldNotDetermine
        return status == .available
    }

    /// Only mutation surface for other modules (coordinator failure reports).
    func reportError(_ message: String) {
        lastError = message
    }

    // MARK: - Becoming owner

    /// Creates the shared zone + zone-wide share and returns the share (the
    /// caller then pushes the initial library into the zone and presents the
    /// standard sharing UI). Zone and share live in the owner's private DB.
    func makeShare(title: String) async throws -> CKShare {
        guard await hasICloudAccount() else { throw SharedLibraryError.noICloudAccount }

        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        // Always the PRIVATE database: zone-wide shares are created in the
        // owner's private DB. The role-based `db` helper would pick the
        // shared DB here, because membership is still `.none` until after
        // creation — and CloudKit rejects private-zone records in the shared
        // DB ("Only shared zones can be accessed in the shared DB",
        // surfacing as a cloudkit.zoneshare fetch error).
        _ = try await container.privateCloudDatabase
            .modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title as NSString

        let result = try await container.privateCloudDatabase
            .modifyRecords(saving: [share], deleting: [],
                           savePolicy: .ifServerRecordUnchanged)
        for (_, outcome) in result.saveResults {
            if case .failure(let error) = outcome { throw error }
        }

        SharedLibrarySettings.ownerZoneName = zoneID.zoneName
        SharedLibrarySettings.ownerZoneOwnerName = zoneID.ownerName
        SharedLibrarySettings.ownerShareRecordName = share.recordID.recordName
        SharedLibrarySettings.shareURL = share.url
        SharedLibrarySettings.shareTitle = title
        SharedLibrarySettings.membership = .owner
        refreshParticipants(from: share)
        return share
    }

    // MARK: - Share lookup

    /// The stored share, refetched from the server. `nil` when never created
    /// or no longer present (zone deleted / sharing stopped).
    func currentShare() async throws -> CKShare? {
        switch SharedLibrarySettings.membership {
        case .owner:
            guard let recordName = SharedLibrarySettings.ownerShareRecordName,
                  let zoneID = SharedLibrarySettings.ownerZoneID else { return nil }
            let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            let results = try await db.records(for: [id])
            guard case .success(let record) = results[id] else { return nil }
            return record as? CKShare
        case .participant:
            guard let zone = try await participantZone() else { return nil }
            guard let ref = zone.share else { return nil }
            let results = try await db.records(for: [ref.recordID])
            guard case .success(let record) = results[ref.recordID] else { return nil }
            return record as? CKShare
        case .none:
            return nil
        }
    }

    /// The accepted zone in the shared database, matched by our fixed zone
    /// name (CKShare doesn't hand participants its zone ID directly). A
    /// self-owned zone can't appear in the shared DB, but the name filter is
    /// also guarded against stale owner state re-entering participant mode.
    private func participantZone() async throws -> CKRecordZone? {
        let zones = try await container.sharedCloudDatabase.allRecordZones()
        return zones.first {
            $0.zoneID.zoneName == Self.zoneName
                && $0.zoneID.ownerName != CKCurrentUserDefaultName
        }
    }

    // MARK: - Participants

    /// Rebuilds `members` from the share's participant list. Works for both
    /// roles; failures land in `lastError` without throwing (list is a
    /// display, not a control flow dependency).
    func refreshParticipants() async {
        do {
            if let share = try await currentShare() {
                refreshParticipants(from: share)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshParticipants(from share: CKShare) {
        var result: [SharedLibraryMember] = []
        let owner = share.owner
        result.append(SharedLibraryMember(
            id: owner.userIdentity.userRecordID?.recordName ?? "owner",
            name: displayName(owner.userIdentity) ?? "Owner",
            isOwner: true,
            isCurrentUser: share.currentUserParticipant?.role == .owner,
            acceptanceStatusDescription: acceptanceText(owner.acceptanceStatus),
            permissionDescription: permissionText(owner.permission)
        ))
        let selfRecordName = share.currentUserParticipant?.userIdentity.userRecordID?.recordName
        for participant in share.participants where participant.role != .owner {
            result.append(SharedLibraryMember(
                id: participant.userIdentity.userRecordID?.recordName
                    ?? participant.userIdentity.lookupInfo?.emailAddress
                    ?? UUID().uuidString,
                name: displayName(participant.userIdentity) ?? "Invited person",
                isOwner: false,
                isCurrentUser: participant.userIdentity.userRecordID?.recordName == selfRecordName,
                acceptanceStatusDescription: acceptanceText(participant.acceptanceStatus),
                permissionDescription: permissionText(participant.permission)
            ))
        }
        members = result
    }

    private func displayName(_ identity: CKUserIdentity) -> String? {
        if let c = identity.nameComponents {
            let name = PersonNameComponentsFormatter().string(from: c)
            if !name.isEmpty { return name }
        }
        return identity.lookupInfo?.emailAddress
    }

    private func acceptanceText(_ status: CKShare.ParticipantAcceptanceStatus) -> String {
        switch status {
        case .accepted: return "Accepted"
        case .pending: return "Invited"
        case .removed: return "Removed"
        default: return "Pending"
        }
    }

    private func permissionText(_ permission: CKShare.ParticipantPermission) -> String {
        switch permission {
        case .readWrite: return "Can make changes"
        case .readOnly: return "View only"
        default: return "—"
        }
    }

    // MARK: - Joining

    /// Processes a share-accept flow end-to-end. Called either from the app
    /// delegate when CloudKit hands over invitation metadata, or at launch
    /// with the persisted pending metadata.
    func accept(metadata: CKShare.Metadata) async throws {
        guard await hasICloudAccount() else { throw SharedLibraryError.noICloudAccount }
        let results = try await container.accept([metadata])
        guard case .success(let share) = results.values.first
            else { throw SharedLibraryError.metadataUnavailable }
        try await finishJoin(share: share)
    }

    /// Stores the accepted share's zone (looked up by our fixed zone name in
    /// the shared database) and flips membership to participant.
    private func finishJoin(share: CKShare) async throws {
        guard let zone = try await zoneLookup() else {
            throw SharedLibraryError.zoneNotFound
        }
        SharedLibrarySettings.acceptedZoneName = zone.zoneID.zoneName
        SharedLibrarySettings.acceptedZoneOwnerName = zone.zoneID.ownerName
        SharedLibrarySettings.shareTitle = (share[CKShare.SystemFieldKey.title] as? String) ?? "Shared Library"
        SharedLibrarySettings.membership = .participant
        SharedLibrarySettings.changeTokenData = nil
        refreshParticipants(from: share)
    }

    /// Polls briefly for the accepted zone to appear in the shared database.
    private func zoneLookup() async throws -> CKRecordZone? {
        for _ in 0..<10 {
            if let zone = try? await participantZone() { return zone }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }
    /// Full sync: pull remote changes into the mirror store, then push local
    /// unsynced edits to the zone. Safe to call repeatedly; coalesces.
    func syncNow(context: ModelContext) async {
        guard SharedLibrarySettings.membership != .none else { return }
        guard syncTask == nil else { return }
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.runSync(context: context)
        }
        syncTask = task
        _ = await task.result
        syncTask = nil
    }

    private func runSync(context: ModelContext) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let status = (try? await container.accountStatus()) ?? .couldNotDetermine
            guard status == .available else {
                // Only reachable when a share exists (membership ≠ none):
                // surfaces in Settings instead of a silently frozen library.
                reportError(status == .noAccount
                            ? "Sign in to iCloud to keep this shared library up to date."
                            : "iCloud is temporarily unavailable — the shared library will sync when it reconnects.")
                return
            }
            guard let zoneID = SharedLibrarySettings.activeZoneID else { return }
            if SharedLibrarySettings.membership == .participant {
                // The zone shows up in the shared DB shortly after accept —
                // and disappears when the owner stops sharing or removes us.
                guard let zone = try await participantZone() else {
                    revokeParticipantLocally()
                    return
                }
                if zone.share == nil {
                    // Zone exists but its share reference is gone — same outcome.
                    revokeParticipantLocally()
                    return
                }
            } else {
                // Owner: make sure the zone exists (fresh-install restore).
                let zones = try await db.recordZones(for: [zoneID])
                if case .failure = zones[zoneID] {
                    _ = try? await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
                }
            }
            try await pullRemoteChanges(context: context, zoneID: zoneID)
            try await pushLocalChanges(context: context, zoneID: zoneID)
            SharedLibrarySettings.lastSyncAt = Date()
            lastError = nil
        } catch is CancellationError {
            // Coalesced-out sync — not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The owner stopped sharing or removed this participant: drop the local
    /// sharing state and flip the provider back for next launch. The mirror
    /// file is kept (its content is the only local copy; "keep a copy" can be
    /// offered manually later) but the index is cleared so nothing re-pushes.
    private func revokeParticipantLocally() {
        reportError("This shared library is no longer available.")
        SharedLibrarySettings.membership = .none
        SharedLibrarySettings.changeTokenData = nil
        // Drop the hash index: its entries are the only delete markers, and
        // with membership gone those records must never re-push anywhere.
        SharedLibraryMirror().saveIndex(SharedLibraryMirror.Index())
        SyncSettings.selectedProvider = SharedLibrarySettings.previousProvider ?? .localOnly
        SharedLibrarySettings.previousProvider = nil
        members = []
    }

    /// Fetches zone changes since the stored token and applies them to the
    /// mirror store. First run (no token) fetches everything.
    private func pullRemoteChanges(context: ModelContext, zoneID: CKRecordZone.ID) async throws {
        var token: CKServerChangeToken?
        if let data = SharedLibrarySettings.changeTokenData {
            token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }

        // Fetch ALL pages before applying: recordZoneChanges returns one page
        // when moreComing is true, and applying per page with a mid-batch
        // failure would leave relationships dangling.
        var changes: [SharedRecordChange] = []
        var assetsByRecordName: [String: Data] = [:]
        var latestToken: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let batch = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
            latestToken = batch.changeToken
            moreComing = batch.moreComing
            token = batch.changeToken
            for (_, outcome) in batch.modificationResultsByID {
                guard case .success(let modification) = outcome else { continue }
                let record = modification.record
                if let change = SharedLibraryRecord.decode(record) {
                    changes.append(change)
                }
                if let asset = SharedLibraryRecord.coverData(from: record) {
                    assetsByRecordName[record.recordID.recordName] = asset
                }
            }
            for deletion in batch.deletions {
                changes.append(SharedRecordChange(kind: .deleted(recordName: deletion.recordID.recordName)))
            }
        }

        let mirror = SharedLibraryMirror()
        var index = mirror.loadIndex()
        let local = mirror.scan(context: context)
        let entriesByName = Dictionary(local.map { ($0.recordName, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let hadDeletes = changes.contains { if case .deleted = $0.kind { return true }; return false }
        let applied = mirror.apply(changes: changes,
                                   assets: assetsByRecordName,
                                   entriesByName: entriesByName,
                                   index: &index,
                                   context: context)
        if applied > 0 || hadDeletes {
            onRemoteChange?()
        }
        mirror.saveIndex(index)
        if let latestToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: latestToken,
                                                        requiringSecureCoding: true) {
            SharedLibrarySettings.changeTokenData = data
        }
    }

    /// Uploads every locally-dirty record (hash-index diff) and deletions.
    private func pushLocalChanges(context: ModelContext, zoneID: CKRecordZone.ID) async throws {
        let mirror = SharedLibraryMirror()
        var index = mirror.loadIndex()
        let entries = mirror.scan(context: context)
        let changes = mirror.pushChanges(entries: entries, index: index)
        guard !changes.isEmpty else { return }

        var toSave: [CKRecord] = []
        var toDelete: [CKRecord.ID] = []
        var pushedEntries: [SharedLibraryMirror.Entry] = []

        for change in changes {
            switch change {
            case .upsert(let entry):
                if let record = recordFor(entry: entry, zoneID: zoneID) {
                    toSave.append(record)
                    pushedEntries.append(entry)
                }
            case .delete(let recordName):
                toDelete.append(CKRecord.ID(recordName: recordName, zoneID: zoneID))
            }
        }

        // .allKeys force-writes every field: our records are synthesized from
        // DTOs (no server change tag, so .changedKeys is undefined for them),
        // and the app-level policy is last-writer-wins per record — a push is
        // meant to overwrite the server copy wholesale.
        let result = try await db.modifyRecords(saving: toSave, deleting: toDelete, savePolicy: .allKeys)
        var failedRecordNames: Set<String> = []
        var deletedRecordNames: Set<String> = []
        for (recordID, outcome) in result.saveResults {
            if case .failure = outcome { failedRecordNames.insert(recordID.recordName) }
        }
        for (recordID, outcome) in result.deleteResults {
            switch outcome {
            case .success: deletedRecordNames.insert(recordID.recordName)
            case .failure: failedRecordNames.insert(recordID.recordName)
            }
        }
        // Per-record failures (server changed, network) stay dirty and retry
        // on the next sync; nothing is silently dropped.
        mirror.markSynced(entries: pushedEntries,
                          failedRecordNames: failedRecordNames,
                          index: &index)
        // Succeeded deletes leave the index immediately (no tombstone rows
        // exist locally — the index entry is the only delete marker).
        for name in deletedRecordNames {
            index.hashes.removeValue(forKey: name)
        }
        mirror.saveIndex(index)
    }

    /// Builds the CKRecord for a locally-scanned entry.
    private func recordFor(entry: SharedLibraryMirror.Entry, zoneID: CKRecordZone.ID) -> CKRecord? {
        if let book = entry.book {
            return SharedLibraryRecord.encode(SharedLibraryMirror.dto(from: book),
                                              coverData: SharedLibraryMirror.bestCoverData(for: book),
                                              inZoneWith: zoneID)
        }
        if let note = entry.note {
            return SharedLibraryRecord.encode(SharedLibraryMirror.dto(from: note), inZoneWith: zoneID)
        }
        if let list = entry.list {
            return SharedLibraryRecord.encode(SharedLibraryMirror.dto(from: list), inZoneWith: zoneID)
        }
        if let item = entry.item {
            return SharedLibraryRecord.encode(SharedLibraryMirror.dto(from: item), inZoneWith: zoneID)
        }
        return nil
    }

    // MARK: - Leaving / stopping

    /// Participant leaves: removes self from the share, then clears local
    /// settings. The coordinator offers "keep a copy" (mirror → private
    /// import) BEFORE calling this; afterwards the mirror store is discarded
    /// and the app relaunches on the private store.
    func leaveAsParticipant() async throws {
        if let share = try await currentShare(), let me = share.currentUserParticipant, me.role != .owner {
            share.removeParticipant(me)
            _ = try? await db.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys)
        }
        SharedLibrarySettings.reset()
        members = []
    }

    /// Owner stops sharing: deletes the zone (revoking everyone's access and
    /// destroying the shared data) and clears local settings.
    func stopSharingAsOwner() async throws {
        if let zoneID = SharedLibrarySettings.ownerZoneID {
            // The owner zone lives in the private DB (see makeShare).
            _ = try? await container.privateCloudDatabase
                .modifyRecordZones(saving: [], deleting: [zoneID])
        }
        SharedLibrarySettings.reset()
        members = []
    }
}

extension CKError {
    var isZoneNotFound: Bool { code == .zoneNotFound }
    var isUnknownItem: Bool { code == .unknownItem }
    var isChangeTokenExpired: Bool { code == .changeTokenExpired }
    var isNotAuthenticated: Bool { code == .notAuthenticated }
}
