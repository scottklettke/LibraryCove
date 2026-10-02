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
        static let preferredShareTitle = "sharedLibrary.preferredShareTitle"
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

    // MARK: - Per-library share state (multi-library sharing)

    /// Namespaced keys: every library carries its own share facts, so
    /// multiple libraries can be shared with different people
    /// simultaneously. `libraryID` is the LibraryScope id.
    static func membership(libraryID: String) -> SharedLibraryMembership {
        SharedLibraryMembership(rawValue: d.string(forKey: "sharedLibrary.\(libraryID).membership") ?? "") ?? .none
    }
    static func setMembership(_ value: SharedLibraryMembership, libraryID: String) {
        d.set(value.rawValue, forKey: "sharedLibrary.\(libraryID).membership")
    }
    static func ownerZoneName(libraryID: String) -> String? {
        d.string(forKey: "sharedLibrary.\(libraryID).ownerZoneName")
    }
    static func setOwnerZoneName(_ value: String?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).ownerZoneName")
    }
    static func ownerZoneOwnerName(libraryID: String) -> String? {
        d.string(forKey: "sharedLibrary.\(libraryID).ownerZoneOwnerName")
    }
    static func setOwnerZoneOwnerName(_ value: String?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).ownerZoneOwnerName")
    }
    static func ownerShareRecordName(libraryID: String) -> String? {
        d.string(forKey: "sharedLibrary.\(libraryID).ownerShareRecordName")
    }
    static func setOwnerShareRecordName(_ value: String?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).ownerShareRecordName")
    }
    static func shareURLString(libraryID: String) -> String? {
        d.string(forKey: "sharedLibrary.\(libraryID).shareURL")
    }
    static func setShareURLString(_ value: String?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).shareURL")
    }
    static func changeTokenData(libraryID: String) -> Data? {
        d.data(forKey: "sharedLibrary.\(libraryID).changeToken")
    }
    static func setChangeTokenData(_ value: Data?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).changeToken")
    }
    static func lastSyncAt(libraryID: String) -> Date? {
        d.object(forKey: "sharedLibrary.\(libraryID).lastSyncAt") as? Date
    }
    static func setLastSyncAt(_ value: Date?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).lastSyncAt")
    }
    static func acceptedZoneName(libraryID: String) -> String? {
        d.string(forKey: "sharedLibrary.\(libraryID).acceptedZoneName")
    }
    static func setAcceptedZoneName(_ value: String?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).acceptedZoneName")
    }
    static func acceptedZoneOwnerName(libraryID: String) -> String? {
        d.string(forKey: "sharedLibrary.\(libraryID).acceptedZoneOwnerName")
    }
    static func setAcceptedZoneOwnerName(_ value: String?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).acceptedZoneOwnerName")
    }

    /// All library ids with a live share (owner or participant).
    /// The current user's participant record name in the active share, when
    /// discoverable (owner: CKCurrentUserDefaultName equivalent via share).
    static var currentUserRecordName: String? {
        d.string(forKey: "sharedLibrary.currentUserRecordName")
    }
    static func setCurrentUserRecordName(_ value: String?, libraryID: String) {
        d.set(value, forKey: "sharedLibrary.\(libraryID).currentUserRecordName")
    }
    static func currentUserRecordName(libraryID: String) -> String? {
        d.string(forKey: "sharedLibrary.\(libraryID).currentUserRecordName")
    }

    /// The default role the owner assigned to the share LINK (what a new
    /// link joiner gets). Stored per library so the Members sheet can
    /// display and admins can change it.
    static func linkDefaultRole(libraryID: String) -> ShareParticipantRole {
        ShareParticipantRole(rawValue: d.string(
            forKey: "sharedLibrary.\(libraryID).linkDefaultRole") ?? "") ?? .editor
    }

    static func setLinkDefaultRole(_ role: ShareParticipantRole, libraryID: String) {
        d.set(role.rawValue, forKey: "sharedLibrary.\(libraryID).linkDefaultRole")
    }

    static var sharedLibraryIDs: [String] {
        let prefix = "sharedLibrary."
        let suffixes: Set<String> = [".membership"]
        return Array(Set(d.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            let rest = key.dropFirst(prefix.count)
            guard suffixes.contains(where: { rest.hasSuffix($0) }) else { return nil }
            let id = rest.dropLast(".membership".count)
            let membership = SharedLibraryMembership(
                rawValue: d.string(forKey: key) ?? "") ?? .none
            return membership == .none ? nil : String(id)
        }))
    }

    /// One-time migration: lifts the legacy single-share state into the
    /// per-library namespace under `libraryID`. Called from the launch
    /// migration for the library the old share is attributed to.
    static func migrateLegacyShare(libraryID: String) {
        guard membership(libraryID: libraryID) == .none else { return }
        if membership != .none {
            setMembership(membership, libraryID: libraryID)
            setOwnerZoneName(ownerZoneName, libraryID: libraryID)
            setOwnerZoneOwnerName(ownerZoneOwnerName, libraryID: libraryID)
            setOwnerShareRecordName(ownerShareRecordName, libraryID: libraryID)
            setShareURLString(d.string(forKey: Key.shareURL), libraryID: libraryID)
            setChangeTokenData(d.data(forKey: Key.changeToken), libraryID: libraryID)
            setLastSyncAt(d.object(forKey: Key.lastSyncAt) as? Date, libraryID: libraryID)
            // Clear the legacy keys so the old single-share UI state is gone.
            d.removeObject(forKey: Key.membership)
            d.removeObject(forKey: Key.ownerZoneName)
            d.removeObject(forKey: Key.ownerZoneOwnerName)
            d.removeObject(forKey: Key.ownerShareRecordName)
            d.removeObject(forKey: Key.shareURL)
            d.removeObject(forKey: Key.acceptedZoneName)
            d.removeObject(forKey: Key.acceptedZoneOwnerName)
            d.removeObject(forKey: Key.changeToken)
            d.removeObject(forKey: Key.lastSyncAt)
        }
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

    /// The library name the user chose at welcome (e.g. "Alex's Library").
    /// Used as the DEFAULT share title when a share is created; reset() does
    /// not clear it because it's the user's library identity, not share
    /// state.
    static var preferredShareTitle: String? {
        get { d.string(forKey: Key.preferredShareTitle) }
        set { d.set(newValue, forKey: Key.preferredShareTitle) }
    }

    /// The standard derived library name for a member: "«Name»'s Library".
    static func defaultShareTitle(for displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\(trimmed)'s Library"
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

    /// Sweeps the LEGACY global share keys without touching
    /// `previousProvider` (the factory-reset provider flip still needs it).
    /// The per-library namespaces stay untouched.
    static func resetLegacyKeys() {
        reset()
    }

    /// Every trace of ONE library's share: membership, zone/share facts,
    /// sync token, and the per-participant role keys — anything under
    /// `sharedLibrary.<id>.`, including shapes added later. Used when a
    /// share ends for that library only.
    static func reset(libraryID: String) {
        let prefix = "sharedLibrary.\(libraryID)."
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            d.removeObject(forKey: key)
        }
    }
}
/// A participant shown in the Members list (retained from the CKShare
/// engine; the Pears members list mirrors this shape).
struct SharedLibraryMember: Identifiable, Equatable {
    var id: String
    var name: String
    var isOwner: Bool
    var isCurrentUser: Bool
    var acceptanceStatusDescription: String
    var permissionDescription: String
}
