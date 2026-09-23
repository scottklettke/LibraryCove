import Testing
import Foundation
import SwiftData
@testable import LibraryCove

/// Registry CloudKit mirror merge rules: remote names converge across the
/// owner's devices (last-writer-wins by modification date) and libraries
/// known only remotely appear locally — without touching the per-device
/// active flag. Offline: exercises `foldRemoteRegistry` only; the CK
/// push/pull paths need an iCloud account the simulator lacks.
@Suite(.serialized) @MainActor struct LibraryRegistryMirrorTests {

    private func withSandboxedRegistry(_ body: () throws -> Void) throws {
        let url = LibraryScope.shared.registryURLForTesting
        let saved = try? Data(contentsOf: url)
        defer {
            if let saved {
                try? saved.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try body()
    }

    private func seed(_ libraries: [LibraryInfo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(libraries)
        try! data.write(to: LibraryScope.shared.registryURLForTesting, options: .atomic)
    }

    private func load() -> [LibraryInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: LibraryScope.shared.registryURLForTesting)
        else { return [] }
        return (try? decoder.decode([LibraryInfo].self, from: data)) ?? []
    }

    @Test func foldTakesNewerRemoteName() throws {
        try withSandboxedRegistry {
            let older = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let newer = older.addingTimeInterval(60)
            seed([LibraryInfo(id: "lib-1", name: "Old Name", isActive: true,
                              createdAt: older, modifiedAt: older)])
            let dto = LibraryRegistryDTO(id: "lib-1", name: "New Name", createdAt: older)
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, newer)]))
            #expect(load().first { $0.id == "lib-1" }?.name == "New Name")
            #expect(load().first { $0.id == "lib-1" }?.modifiedAt == newer)
        }
    }

    @Test func foldKeepsLocallyNewerName() throws {
        try withSandboxedRegistry {
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            // Local renamed AFTER the remote record was modified.
            seed([LibraryInfo(id: "lib-1", name: "Local Rename", isActive: true,
                              createdAt: base, modifiedAt: base.addingTimeInterval(120))])
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Stale Remote", createdAt: base)
            #expect(!LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(60))]))
            #expect(load().first { $0.id == "lib-1" }?.name == "Local Rename")
        }
    }

    @Test func foldAppendsRemoteOnlyLibrary() throws {
        try withSandboxedRegistry {
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            seed([LibraryInfo(id: LibraryScope.defaultLibraryID, name: "", isActive: true,
                              createdAt: base, modifiedAt: nil)])
            let dto = LibraryRegistryDTO(id: "shared-abc", name: "Reading 2026", createdAt: base)
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, base)]))
            let libs = load()
            #expect(libs.count == 2)
            let appended = libs.first { $0.id == "shared-abc" }
            #expect(appended?.name == "Reading 2026")
            #expect(appended?.isActive == false, "active flag is per-device")
            #expect(libs.first { $0.id == LibraryScope.defaultLibraryID }?.isActive == true)
        }
    }

    @Test func foldIsNoopOnIdenticalNames() throws {
        try withSandboxedRegistry {
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            seed([LibraryInfo(id: "lib-1", name: "Same", isActive: true,
                              createdAt: base, modifiedAt: nil)])
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Same", createdAt: base)
            #expect(!LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(60))]))
            #expect(load().first { $0.id == "lib-1" }?.name == "Same")
        }
    }

    @Test func wipeRemovesPreWipeEntriesAndKeepsPostWipe() throws {
        try withSandboxedRegistry {
            let wipe = Date(timeIntervalSinceReferenceDate: 2_000_000)
            // Pre-wipe libraries (the stale ones the user saw survive).
            seed([
                LibraryInfo(id: "old-1", name: "Stale", isActive: true,
                            createdAt: Date(timeIntervalSinceReferenceDate: 1_000_000),
                            modifiedAt: nil),
                LibraryInfo(id: "old-2", name: "Also Stale", isActive: false,
                            createdAt: Date(timeIntervalSinceReferenceDate: 1_100_000),
                            modifiedAt: nil),
                // Renamed AFTER the wipe: post-wipe state survives.
                LibraryInfo(id: "fresh", name: "Kept", isActive: false,
                            createdAt: Date(timeIntervalSinceReferenceDate: 1_200_000),
                            modifiedAt: wipe.addingTimeInterval(60)),
            ])
            #expect(LibraryScope.shared.foldRemoteRegistry([], wipedAt: wipe))
            let libs = load()
            #expect(!libs.contains { $0.id == "old-1" || $0.id == "old-2" })
            #expect(libs.first { $0.id == "fresh" }?.name == "Kept")
            // The surviving post-wipe library became active.
            #expect(libs.first { $0.isActive }?.id == "fresh")
        }
    }

    @Test func wipeOnEmptyRegistryCreatesDefault() throws {
        try withSandboxedRegistry {
            seed([LibraryInfo(id: "old-1", name: "Stale", isActive: true,
                              createdAt: Date(timeIntervalSinceReferenceDate: 1_000_000),
                              modifiedAt: nil)])
            #expect(LibraryScope.shared.foldRemoteRegistry([], wipedAt: Date()))
            let libs = load()
            #expect(libs.count == 1)
            #expect(libs.first?.id == LibraryScope.defaultLibraryID)
            #expect(libs.first?.isActive == true)
        }
    }

    @Test func foldRemovesLocalsAbsentFromRemoteSet() throws {
        try withSandboxedRegistry {
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            seed([
                LibraryInfo(id: "lib-1", name: "Kept", isActive: true,
                            createdAt: base, modifiedAt: nil),
                LibraryInfo(id: "lib-gone", name: "Deleted Elsewhere", isActive: false,
                            createdAt: base, modifiedAt: base.addingTimeInterval(120)),
            ])
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Kept", createdAt: base)
            // lib-gone has NO remote record: it was deleted on another
            // device, so the fold removes it even though it was modified
            // more recently than lib-1's record.
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, base)]))
            let libs = load()
            #expect(libs.count == 1)
            #expect(libs.first?.id == "lib-1")
            #expect(libs.first?.isActive == true)
        }
    }

    @Test func foldAdoptsWholesaleOnFreshRegistry() throws {
        try withSandboxedRegistry {
            let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
            // Empty local registry (fresh device or recreated after a
            // wipe) + populated remote: adopt everything, including the
            // writer's active flag — the "Untitled" on a fresh device bug.
            // Seeded explicitly: parallel suites share the real registry
            // file, so emptiness must not be assumed.
            seed([])
            #expect(load().isEmpty)
            let dto = LibraryRegistryDTO(id: "u1", name: "My Library", createdAt: t,
                                         modifiedAt: t, isActive: true)
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, t)]))
            let libs = load()
            #expect(libs.count == 1)
            #expect(libs.first?.name == "My Library")
            #expect(libs.first?.isActive == true)
            #expect(LibraryScope.shared.activeIDForTesting == "u1")
        }
    }

    @Test func foldAdoptsRemoteNameForLocallyUnnamedLibrary() throws {
        try withSandboxedRegistry {
            // The reported iPad bug: the iPad's default library was never
            // named locally (name ""), and its stamp is NEWER than the
            // other device's rename — yet the remote name must win,
            // otherwise the banner falls back to "«Member»'s Library" and
            // tracks user-name edits instead of the library name.
            let localCreated = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let remoteRename = localCreated.addingTimeInterval(-60)
            seed([LibraryInfo(id: LibraryScope.defaultLibraryID, name: "", isActive: true,
                              createdAt: localCreated, modifiedAt: nil)])
            let dto = LibraryRegistryDTO(id: LibraryScope.defaultLibraryID,
                                         name: "Tom's Library", createdAt: remoteRename,
                                         modifiedAt: remoteRename)
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, remoteRename)]))
            let lib = load().first { $0.id == LibraryScope.defaultLibraryID }
            #expect(lib?.name == "Tom's Library")
            #expect(lib?.modifiedAt == localCreated, "keeps the newer local stamp")
        }
    }

    @Test func foldIgnoresPreWipeRemoteEntries() throws {
        try withSandboxedRegistry {
            let wipe = Date(timeIntervalSinceReferenceDate: 2_000_000)
            // Post-wipe local registry ("Kept" was renamed after the wipe).
            seed([LibraryInfo(id: "fresh", name: "Kept", isActive: true,
                              createdAt: wipe.addingTimeInterval(10),
                              modifiedAt: wipe.addingTimeInterval(60))])
            // Remote record stamped BEFORE the wipe with the old name: the
            // resurrection bug — it must neither rename nor re-append.
            let stale = LibraryRegistryDTO(id: "fresh", name: "Alex's Library",
                                           createdAt: Date(timeIntervalSinceReferenceDate: 1_000_000),
                                           modifiedAt: Date(timeIntervalSinceReferenceDate: 1_500_000))
            #expect(!LibraryScope.shared.foldRemoteRegistry([(stale, wipe.addingTimeInterval(-30))],
                                                            wipedAt: wipe))
            let libs = load()
            #expect(libs.count == 1)
            #expect(libs.first?.name == "Kept")
        }
    }

    // MARK: - Delta fetches (fullSnapshot: false)

    @Test func deltaAppliesRenameByStamp() throws {
        try withSandboxedRegistry {
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            seed([
                LibraryInfo(id: "lib-1", name: "Old", isActive: true,
                            createdAt: base, modifiedAt: base),
                LibraryInfo(id: "lib-2", name: "Untouched", isActive: false,
                            createdAt: base, modifiedAt: base),
            ])
            // Delta carries ONLY the changed record; lib-2's absence means
            // nothing on a delta.
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Renamed Remotely",
                                         createdAt: base, modifiedAt: base.addingTimeInterval(60))
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(60))],
                                                           fullSnapshot: false))
            let libs = load()
            #expect(libs.first { $0.id == "lib-1" }?.name == "Renamed Remotely")
            // Untouched entry survives — absence-removal must NOT run.
            #expect(libs.count == 2)
            #expect(libs.first { $0.id == "lib-2" }?.name == "Untouched")
        }
    }

    @Test func deltaAppliesRemoteDeletionAndPromotesActive() throws {
        try withSandboxedRegistry {
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            seed([
                LibraryInfo(id: "lib-gone", name: "Deleted Elsewhere", isActive: true,
                            createdAt: base, modifiedAt: base),
                LibraryInfo(id: "lib-2", name: "Survivor", isActive: false,
                            createdAt: base, modifiedAt: base),
            ])
            #expect(LibraryScope.shared.foldRemoteRegistry([], deletions: ["lib-gone"],
                                                           fullSnapshot: false))
            let libs = load()
            #expect(libs.count == 1)
            #expect(libs.first?.id == "lib-2")
            // The deleted library was active: the survivor is promoted.
            #expect(libs.first?.isActive == true)
        }
    }

    @Test func deltaNeverRecreatesDefault() throws {
        try withSandboxedRegistry {
            // Empty registry + delta with no entries: step 3 (default
            // recreation) is full-fetch-only, so no phantom default — the
            // push path will publish local state instead.
            seed([])
            #expect(!LibraryScope.shared.foldRemoteRegistry([], fullSnapshot: false))
            #expect(load().isEmpty)
        }
    }

    @Test func deltaAppendsRemoteOnlyLibrary() throws {
        try withSandboxedRegistry {
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            seed([LibraryInfo(id: "lib-1", name: "Home", isActive: true,
                              createdAt: base, modifiedAt: base)])
            // A NEW library created remotely arrives via a delta.
            let dto = LibraryRegistryDTO(id: "new-lib", name: "Reading 2026",
                                         createdAt: base.addingTimeInterval(30),
                                         modifiedAt: base.addingTimeInterval(30))
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(30))],
                                                           fullSnapshot: false))
            let libs = load()
            #expect(libs.count == 2)
            #expect(libs.first { $0.id == "new-lib" }?.name == "Reading 2026")
            // The appended remote library is NOT active here (per-device
            // active flag is untouched by an append).
            #expect(libs.first { $0.id == "new-lib" }?.isActive == false)
            #expect(libs.first { $0.id == "lib-1" }?.isActive == true)
        }
    }

    // MARK: - Share-facts mirroring (share events have their own clock)

    @Test func foldAdoptsSharePublish() throws {
        try withSandboxedRegistry {
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            seed([LibraryInfo(id: "lib-1", name: "Home", isActive: true,
                              createdAt: base, modifiedAt: base)])
            let facts = LibraryRegistryDTO.ShareFacts(
                zoneName: "LibraryCoveSharedLibrary-1234",
                zoneOwnerName: "_a1b2c3",
                shareRecordName: "share-xyz",
                stampedAt: base.addingTimeInterval(60))
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Home", createdAt: base,
                                         modifiedAt: base.addingTimeInterval(60),
                                         share: facts)
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(60))]))
            #expect(load().first { $0.id == "lib-1" }?.share == facts)
            // Adoption seeds this device's share state so the Settings
            // management section renders here too.
            #expect(SharedLibrarySettings.membership(libraryID: "lib-1") == .owner)
            #expect(SharedLibrarySettings.ownerZoneName(libraryID: "lib-1") == facts.zoneName)
            #expect(SharedLibrarySettings.ownerShareRecordName(libraryID: "lib-1") == facts.shareRecordName)
            SharedLibrarySettings.reset(libraryID: "lib-1")
        }
    }

    @Test func foldIgnoresStaleSharePublishAfterClear() throws {
        try withSandboxedRegistry {
            // THE PING-PONG REGRESSION: a device stopped sharing, then a
            // peer's re-push of the OLD publish block (verbatim, older
            // stampedAt) arrives. The share clock must keep the share
            // dead — the peer's entry stamp is irrelevant.
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let publish = base.addingTimeInterval(60)
            let stop = base.addingTimeInterval(120)
            let facts = LibraryRegistryDTO.ShareFacts(
                zoneName: "z", zoneOwnerName: "o", shareRecordName: "s",
                stampedAt: publish)
            seed([LibraryInfo(id: "lib-1", name: "Home", isActive: true,
                              createdAt: base, modifiedAt: base.addingTimeInterval(90),
                              shareClearedAt: stop)])
            // Remote record still carrying the pre-stop publish (e.g. a
            // peer that hasn't pulled the stop yet), re-pushed later.
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Home", createdAt: base,
                                         modifiedAt: base.addingTimeInterval(600),
                                         share: facts)
            #expect(!LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(600))]))
            let lib = load().first { $0.id == "lib-1" }
            #expect(lib?.share == nil)
            #expect(lib?.shareClearedAt == stop)
        }
    }

    @Test func foldClearsOnNewerStopEvent() throws {
        try withSandboxedRegistry {
            // Peer adopted the owner's publish (clock included), then
            // renamed (bumping the ENTRY stamp without touching the share
            // clock). The owner stops sharing: the stop event beats the
            // held publish clock, so the clear lands despite the newer
            // entry stamp — and adoptShareFacts drops the local share UI.
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let publish = base.addingTimeInterval(60)
            let stop = base.addingTimeInterval(500)
            let facts = LibraryRegistryDTO.ShareFacts(
                zoneName: "z", zoneOwnerName: "o", shareRecordName: "s",
                stampedAt: publish)
            seed([LibraryInfo(id: "lib-1", name: "Locally Renamed", isActive: true,
                              createdAt: base, modifiedAt: base.addingTimeInterval(300),
                              share: facts)])
            #expect(SharedLibrarySettings.membership(libraryID: "lib-1") == .none)
            SharedLibrarySettings.setMembership(.owner, libraryID: "lib-1")
            SharedLibrarySettings.setOwnerZoneName("z", libraryID: "lib-1")
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Locally Renamed",
                                         createdAt: base,
                                         modifiedAt: base.addingTimeInterval(120),
                                         shareClearedAt: stop)
            #expect(LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(120))]))
            let lib = load().first { $0.id == "lib-1" }
            #expect(lib?.share == nil)
            #expect(lib?.shareClearedAt == stop)
            #expect(SharedLibrarySettings.membership(libraryID: "lib-1") == .none)
        }
    }

    @Test func foldKeepsHeldPublishAgainstOlderStop() throws {
        try withSandboxedRegistry {
            // A record carrying a stop event OLDER than the publish this
            // device already holds (e.g. a stale snapshot with a cleared
            // marker from a previous share generation) must not kill the
            // live share.
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let oldStop = base.addingTimeInterval(10)
            let publish = base.addingTimeInterval(60)
            let facts = LibraryRegistryDTO.ShareFacts(
                zoneName: "z2", zoneOwnerName: "o2", shareRecordName: "s2",
                stampedAt: publish)
            seed([LibraryInfo(id: "lib-1", name: "Home", isActive: true,
                              createdAt: base, modifiedAt: base.addingTimeInterval(90),
                              share: facts)])
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Home", createdAt: base,
                                         modifiedAt: base.addingTimeInterval(120),
                                         shareClearedAt: oldStop)
            #expect(!LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(120))]))
            #expect(load().first { $0.id == "lib-1" }?.share == facts)
        }
    }

    @Test func foldIgnoresNilShareWhenNothingHeld() throws {
        try withSandboxedRegistry {
            // nil-share vs nothing-held is a no-op (no share clock moves).
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            seed([LibraryInfo(id: "lib-1", name: "Home", isActive: true,
                              createdAt: base, modifiedAt: base)])
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Home", createdAt: base,
                                         modifiedAt: base.addingTimeInterval(60))
            #expect(!LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(60))]))
            #expect(load().first { $0.id == "lib-1" }?.share == nil)
        }
    }

    @Test func activatePreservesShareClocks() throws {
        try withSandboxedRegistry {
            // Library switches rebuild every registry entry through
            // activate(); dropping the stop event there would resurrect the
            // dead share on the next pull. Both clocks must survive — and
            // locally-adopted owner keys must not re-seed.
            let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let publish = base.addingTimeInterval(60)
            let stop = base.addingTimeInterval(120)
            let facts = LibraryRegistryDTO.ShareFacts(
                zoneName: "z", zoneOwnerName: "o", shareRecordName: "s",
                stampedAt: publish)
            seed([
                LibraryInfo(id: "lib-1", name: "Shared One", isActive: true,
                            createdAt: base, modifiedAt: base.addingTimeInterval(90),
                            shareClearedAt: stop),
                LibraryInfo(id: "lib-2", name: "Other", isActive: false,
                            createdAt: base, modifiedAt: base),
            ])
            // Adopted owner keys from a pre-clear pull on this device.
            SharedLibrarySettings.setMembership(.owner, libraryID: "lib-1")
            SharedLibrarySettings.setOwnerZoneName("z", libraryID: "lib-1")
            LibraryScope.shared.activate(
                LibraryInfo(id: "lib-2", name: "Other", isActive: true,
                            createdAt: base, modifiedAt: base),
                context: Persistence.shared.mainContext)
            let lib1 = load().first { $0.id == "lib-1" }
            #expect(lib1?.shareClearedAt == stop)
            #expect(lib1?.share == nil)
            // adoptShareFacts dropped the stale adopted keys (share is nil).
            #expect(SharedLibrarySettings.membership(libraryID: "lib-1") == .none)
            // The clear event survives a later pull of the stale publish.
            // lib-2 must be in the remote set too — absence-removal would
            // otherwise return true for the wrong reason.
            let dto = LibraryRegistryDTO(id: "lib-1", name: "Shared One",
                                         createdAt: base,
                                         modifiedAt: base.addingTimeInterval(600),
                                         share: facts)
            let dto2 = LibraryRegistryDTO(id: "lib-2", name: "Other",
                                          createdAt: base,
                                          modifiedAt: base)
            #expect(!LibraryScope.shared.foldRemoteRegistry([(dto, base.addingTimeInterval(600)),
                                                             (dto2, base)]))
            #expect(load().first { $0.id == "lib-1" }?.share == nil)
        }
    }
}
