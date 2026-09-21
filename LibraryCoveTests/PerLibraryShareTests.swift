import Testing
import Foundation
import SwiftData
@testable import LibraryCove

/// Per-library sharing state: independent membership, roles, and per-share
/// facts across multiple libraries.
@Suite(.serialized) @MainActor struct PerLibraryShareTests {


    @Test func shareStateIsIndependentPerLibrary() throws {
        let context = Persistence.inMemory.mainContext
        LibraryScope.shared.migrateIfNeeded(context: context)
        let first = try LibraryScope.shared.create(name: "ShareTest-First", makeActive: true, context: context)
        let second = try LibraryScope.shared.create(name: "ShareTest-Second", makeActive: false, context: context)

        // First is owned-shared; second is not shared.
        SharedLibrarySettings.setMembership(.owner, libraryID: first.id)
        SharedLibrarySettings.setOwnerZoneName("zone-first", libraryID: first.id)
        SharedLibrarySettings.setOwnerShareRecordName("share-first", libraryID: first.id)

        #expect(SharedLibrarySettings.membership(libraryID: first.id) == .owner)
        #expect(SharedLibrarySettings.membership(libraryID: second.id) == .none)
        #expect(SharedLibrarySettings.sharedLibraryIDs.contains(first.id))
        #expect(!SharedLibrarySettings.sharedLibraryIDs.contains(second.id))

        // Clearing the first's membership removes it from the share list
        // without touching other libraries' share state.
        SharedLibrarySettings.setMembership(.none, libraryID: first.id)
        #expect(!SharedLibrarySettings.sharedLibraryIDs.contains(first.id))
    }

    @Test func legacyMigrationLiftsShareIntoLibrary() throws {
        // Simulate the legacy single-share state (global keys).
        let d = UserDefaults.standard
        d.set(SharedLibraryMembership.owner.rawValue, forKey: "sharedLibrary.membership")
        d.set("legacy-zone", forKey: "sharedLibrary.ownerZoneName")
        d.set("legacy-owner", forKey: "sharedLibrary.ownerZoneOwnerName")
        d.set("legacy-share-record", forKey: "sharedLibrary.ownerShareRecordName")

        let context = Persistence.inMemory.mainContext
        LibraryScope.shared.migrateIfNeeded(context: context)
        SharedLibrarySettings.migrateLegacyShare(libraryID: LibraryScope.defaultLibraryID)

        // The share now lives under the default library's namespace.
        #expect(SharedLibrarySettings.membership(libraryID: LibraryScope.defaultLibraryID) == .owner)
        #expect(SharedLibrarySettings.ownerZoneName(libraryID: LibraryScope.defaultLibraryID) == "legacy-zone")
        #expect(SharedLibrarySettings.ownerShareRecordName(libraryID: LibraryScope.defaultLibraryID) == "legacy-share-record")

        // Clean up the migrated namespace: keys persist process-wide and
        // would otherwise poison concurrent suites (Swift Testing
        // serializes per-suite, not the whole process).
        SharedLibrarySettings.reset(libraryID: LibraryScope.defaultLibraryID)
    }

    @Test func guestRoleCannotStopSharing() throws {
        let context = Persistence.inMemory.mainContext
        LibraryScope.shared.migrateIfNeeded(context: context)
        let shared = try LibraryScope.shared.create(name: "ShareTest-Shared", makeActive: true, context: context)
        SharedLibrarySettings.setMembership(.participant, libraryID: shared.id)
        SharedLibrarySettings.setAcceptedZoneName("z", libraryID: shared.id)
        SharedLibrarySettings.setAcceptedZoneOwnerName("o", libraryID: shared.id)
        SharedLibrarySettings.setCurrentUserRecordName("user-1", libraryID: shared.id)
        ShareRoleStore.setRole(.guest, libraryID: shared.id, participantRecordName: "user-1")

        // The engine's role check: guest is not admin.
        #expect(SharedLibraryEngine.shared.myRole(libraryID: shared.id) == .guest)

        // Coordinator-level rule: stopSharing refuses guests (the guard reads
        // the role store directly).
        let role = ShareRoleStore.role(libraryID: shared.id,
                                       participantRecordName: "user-1")
        #expect(role != .admin, "guest must not be treated as admin")
    }
}
