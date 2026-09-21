import Testing
import Foundation
@testable import LibraryCove

/// "Delete everything and start fresh": every library's share state must
/// be wiped — including non-active per-library shares the legacy gate
/// cannot see — so nothing re-attaches to the re-created default library
/// (fixed id `library-default`). UserDefaults-level only: the simulator
/// has no iCloud account, so the CloudKit calls inside the teardown fail
/// and are swallowed per library (owner path via `try?`, participant and
/// legacy paths via the coordinator's catch).
@Suite(.serialized) @MainActor struct DeleteEverythingShareTeardownTests {

    private static let relevantKey: (String) -> Bool = {
        $0.hasPrefix("sharedLibrary.") || $0 == "syncProvider"
    }

    /// Saves, clears, and afterwards restores every `sharedLibrary.*` and
    /// `syncProvider` key, so the suite never leaks state into sibling
    /// tests (Swift Testing serializes per suite only). Returns the
    /// post-seed baseline: assertions diff against it because OTHER
    /// suites run concurrently (serialization is per-suite) and may write
    /// keys mid-test — e.g. `PerLibraryShareTests` migrating legacy
    /// globals into `library-default.*` while the teardown awaits
    /// CloudKit timeouts.
    private func withSandboxedSharedState(
        _ seed: () -> Void,
        _ body: (Set<String>) async throws -> Void
    ) async throws {
        let d = UserDefaults.standard
        let saved = d.dictionaryRepresentation().filter { Self.relevantKey($0.key) }
        defer {
            for key in d.dictionaryRepresentation().keys
            where Self.relevantKey(key) && saved[key] == nil {
                d.removeObject(forKey: key)
            }
            for (key, value) in saved {
                d.set(value, forKey: key)
            }
        }
        for (key, _) in saved {
            d.removeObject(forKey: key)
        }
        seed()
        let baseline = Set(d.dictionaryRepresentation().keys.filter(Self.relevantKey))
        try await body(baseline)
    }

    @Test func teardownClearsEveryLibraryShareAndLegacyKeys() async throws {
        try await withSandboxedSharedState({
            // Two per-library shares (owner + participant) — the per-library
            // era never writes the legacy global membership key, so the old
            // gate saw neither of these.
            SharedLibrarySettings.setMembership(.owner, libraryID: "lib-owner")
            SharedLibrarySettings.setOwnerZoneName("zone-a", libraryID: "lib-owner")
            SharedLibrarySettings.setOwnerZoneOwnerName("owner-a", libraryID: "lib-owner")
            SharedLibrarySettings.setOwnerShareRecordName("share-a", libraryID: "lib-owner")
            SharedLibrarySettings.setMembership(.participant, libraryID: "lib-part")
            SharedLibrarySettings.setAcceptedZoneName("zone-b", libraryID: "lib-part")
            SharedLibrarySettings.setAcceptedZoneOwnerName("owner-b", libraryID: "lib-part")
            SharedLibrarySettings.setCurrentUserRecordName("user-b", libraryID: "lib-part")
            ShareRoleStore.setRole(.editor, libraryID: "lib-part", participantRecordName: "user-b")
            // Legacy-era global keys, as on a not-yet-migrated device.
            UserDefaults.standard.set(SharedLibraryMembership.participant.rawValue,
                                      forKey: "sharedLibrary.membership")
            UserDefaults.standard.set("legacy-zone", forKey: "sharedLibrary.ownerZoneName")
            UserDefaults.standard.set("Some Title", forKey: "sharedLibrary.shareTitle")
            UserDefaults.standard.set(LibrarySync.localOnly.rawValue,
                                      forKey: "sharedLibrary.previousProvider")
        }, { baseline in
            #expect(SharedLibrarySettings.sharedLibraryIDs.count == 2)

            await SharedLibraryCoordinator.discardAllSharedContent()

            let remaining = UserDefaults.standard.dictionaryRepresentation().keys
                .filter { $0.hasPrefix("sharedLibrary.") }
            // Disjointness against the seeded baseline: every key THIS
            // test seeded must be gone. A concurrent suite (serialization
            // is per-suite) may add its own sharedLibrary.* keys while
            // this awaits CloudKit timeouts — those foreign keys must not
            // fail the assertion, and diffing the other direction would
            // wrongly ignore seeded survivors.
            #expect(Set(remaining).isDisjoint(with: baseline),
                    "seeded sharedLibrary.* keys must be gone, left: \(Set(remaining).intersection(baseline).sorted())")
            #expect(SharedLibrarySettings.sharedLibraryIDs
                .allSatisfy { !baseline.contains("sharedLibrary.\($0).membership") })
            // The epilogue's provider flip honors previousProvider (here
            // localOnly) BEFORE the caller's final sweep — deleteAllData
            // wipes whichever store that selects. The raw key holds
            // localOnly; the getter normalizes it to .iCloud.
            #expect(UserDefaults.standard.string(forKey: "syncProvider")
                    == LibrarySync.localOnly.rawValue)
        })
    }

    @Test func teardownIsNoopWithoutShareState() async throws {
        try await withSandboxedSharedState({}, { baseline in
            await SharedLibraryCoordinator.discardAllSharedContent()
            let remaining = UserDefaults.standard.dictionaryRepresentation().keys
                .filter { $0.hasPrefix("sharedLibrary.") }
            // Baseline is empty here: sharp when clean, vacuous if a
            // concurrent suite is mid-write (keys it added are not ours
            // to assert on).
            #expect(Set(remaining).isDisjoint(with: baseline))
            #expect(SyncSettings.selectedProvider == .iCloud)
        })
    }

    @Test func perLibraryResetSparesOtherLibraries() async throws {
        try await withSandboxedSharedState({
            let d = UserDefaults.standard
            SharedLibrarySettings.setMembership(.owner, libraryID: "lib-keep")
            SharedLibrarySettings.setOwnerZoneName("zone-keep", libraryID: "lib-keep")
            SharedLibrarySettings.setMembership(.participant, libraryID: "lib-drop")
            SharedLibrarySettings.setAcceptedZoneName("zone-drop", libraryID: "lib-drop")
            ShareRoleStore.setRole(.guest, libraryID: "lib-drop", participantRecordName: "u1")
            d.set("t", forKey: "sharedLibrary.shareTitle")
        }, { _ in
            let d = UserDefaults.standard
            SharedLibrarySettings.reset(libraryID: "lib-drop")

            #expect(SharedLibrarySettings.membership(libraryID: "lib-keep") == .owner)
            #expect(SharedLibrarySettings.ownerZoneName(libraryID: "lib-keep") == "zone-keep")
            #expect(SharedLibrarySettings.membership(libraryID: "lib-drop") == .none)
            #expect(d.string(forKey: "sharedLibrary.shareTitle") == "t")
            // Role keys live under the swept prefix: gone for the dropped
            // library only.
            #expect(d.string(forKey: "sharedLibrary.lib-drop.role.u1") == nil)
        })
    }
}
