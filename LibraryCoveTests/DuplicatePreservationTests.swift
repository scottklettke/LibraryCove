import Testing
import Foundation
import SwiftData
@testable import LibraryCove

/// Throwaway verification for the duplicates-preserved pipeline:
/// export → restore (importArchive) → export must keep same-title copies.
@Suite(.serialized) @MainActor struct DuplicatePreservationTests {

    /// Own container: `Persistence.inMemory.mainContext` is shared across
    /// suites (Swift Testing serializes per SUITE, not the process —
    /// LibraryCoveTests/StopSharingMigrationTests/MultiLibraryTests all use
    /// it), and an interleaving suite touching the shared store during this
    /// test's export await crashed the store connection (reproduced twice).
    private static let container: ModelContainer = {
        let schema = Schema([Book.self, Note.self, ReadingList.self,
                             ReadingListItem.self, Connection.self, User.self])
        return try! ModelContainer(for: schema,
                                   configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }()

    private func baseContext() -> ModelContext {
        ModelContext(Self.container)
    }

    @Test func exportImportExportPreservesDuplicates() async throws {
        let context = baseContext()

        // Mirror the real app: launch migration tags legacy rows into the
        // default library. Migration no longer synthesizes a default on an
        // empty registry, so tests create one explicitly with the FIXED
        // default id (migrateArchive/copyArchive key off the active id).
        LibraryScope.shared.migrateIfNeeded(context: context)
        if LibraryScope.shared.all(context: context)
            .first(where: { $0.id == LibraryScope.defaultLibraryID }) == nil {
            LibraryScope.shared.activate(
                LibraryInfo(id: LibraryScope.defaultLibraryID, name: "Default",
                            isActive: true, createdAt: Date(), modifiedAt: Date()),
                context: context)
        } else if let defaultLibrary = LibraryScope.shared.all(context: context)
            .first(where: { $0.id == LibraryScope.defaultLibraryID }) {
            LibraryScope.shared.activate(defaultLibrary, context: context)
        }
        let activeLibraryID = LibraryScope.shared.activeID(context: context)
        let user = User(id: "u-d", email: "d@d.c", displayName: "Dup", isActive: true)
        context.insert(user)
        // Two copies of the SAME book: same title/authors/ISBN, distinct ids.
        let a = Book(id: "dup-a", title: "Dune", authors: ["Frank Herbert"],
                     isbn: "9780441172719", ownerID: "u-d",
                     createdAt: Date(timeIntervalSince1970: 1000))
        let b = Book(id: "dup-b", title: "Dune", authors: ["Frank Herbert"],
                     isbn: "9780441172719", ownerID: "u-d",
                     createdAt: Date(timeIntervalSince1970: 2000))
        a.libraryID = activeLibraryID
        b.libraryID = activeLibraryID
        context.insert(a)
        context.insert(b)
        try context.save()

        // 1) Backup-now path: export → BackupStore.save → read back.
        guard let zip1 = await LibraryDataService.export(context: context) else {
            Issue.record("export failed"); return
        }
        let name = try BackupStore.save(data: zip1, bookCount: 2, libraryName: "Test Library")
        defer { BackupStore.deleteAll() }
        let items = BackupStore.list()
        #expect(items.contains { $0.name == name })
        let storedData = try Data(contentsOf: items.first { $0.name == name }!.url)
        let back1 = try LibraryDataService.archiveBooks(data: storedData)
        #expect(back1.count == 2, "backup zip must contain BOTH copies, got \(back1.count)")

        // 2) Replace-restore path: importArchive into a wiped store.
        // deleteAll clears the registry (no active library); recreate the
        // fixed-id default so importArchive tags restored rows into it.
        LibraryDataService.deleteAll(context: context)
        if LibraryScope.shared.all(context: context)
            .first(where: { $0.id == LibraryScope.defaultLibraryID }) == nil {
            LibraryScope.shared.activate(
                LibraryInfo(id: LibraryScope.defaultLibraryID, name: "Test Library",
                            isActive: true, createdAt: Date(), modifiedAt: Date()),
                context: context)
        }
        let summary = try LibraryDataService.importArchive(data: zip1, context: context)
        #expect(summary.books == 2, "restore must reinstate BOTH copies, got \(summary.books)")
        let rows = try context.fetch(FetchDescriptor<Book>())
        #expect(rows.count == 2, "store must hold BOTH copies after restore, got \(rows.count)")

        // 3) copyArchive path (shared-library hand-off): pour into a store
        // that already has one copy — the distinct-id second copy must
        // survive, and same-id rows must not double-insert.
        let summary2 = try LibraryDataService.copyArchive(data: zip1, context: context)
        _ = summary2
        let rowsAfterCopy = try context.fetch(FetchDescriptor<Book>())
        #expect(rowsAfterCopy.count == 2, "copyArchive must not double-insert same-id rows, got \(rowsAfterCopy.count)")

        // 4) migrateArchive path (provider switch): a target polluted with
        // a stale era (extra rows with ids the snapshot lacks) must end up
        // EXACTLY the snapshot: stale rows deleted, duplicates preserved.
        let stale = Book(id: "stale-1", title: "Old Flood Book", authors: ["F. Lood"],
                         isbn: nil, ownerID: "u-d",
                         createdAt: Date(timeIntervalSince1970: 500))
        stale.libraryID = activeLibraryID
        context.insert(stale)
        try context.save()
        let before = try context.fetch(FetchDescriptor<Book>())
        #expect(before.count == 3, "polluted store should hold 3 rows, got \(before.count)")
        _ = try LibraryDataService.migrateArchive(data: zip1, context: context)
        let after = try context.fetch(FetchDescriptor<Book>())
        #expect(after.count == 2, "migration must remove stale rows, got \(after.count)")
        #expect(!after.contains { $0.id == "stale-1" }, "stale row must be gone")
        #expect(after.contains { $0.id == "dup-a" } && after.contains { $0.id == "dup-b" },
                "both duplicate copies must survive migration")
    }
    /// The backup filename must carry the library it came from, so users
    /// with several libraries (or parked Local/iCloud sets) can tell them
    /// apart. Same-day backups of DIFFERENT libraries must not collide or
    /// share a sequence run.
    @Test func backupNameCarriesLibraryNameAndSequencesPerLibrary() throws {
        defer { BackupStore.deleteAll() }
        let data = Data("zip".utf8)
        let day = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        let n1 = try BackupStore.save(data: data, bookCount: 2, libraryName: "Home")
        #expect(n1 == "Home \(day) (2 books)", "first Home backup of the day: got \(n1)")
        let n2 = try BackupStore.save(data: data, bookCount: 3, libraryName: "Home")
        #expect(n2 == "Home \(day) (3 books) 2", "second Home backup gains sequence 2: got \(n2)")
        let n3 = try BackupStore.save(data: data, bookCount: 4, libraryName: "Home")
        #expect(n3 == "Home \(day) (4 books) 3", "third Home backup gains sequence 3: got \(n3)")

        // A different library the same day starts its own sequence run.
        let o1 = try BackupStore.save(data: data, bookCount: 1, libraryName: "Office")
        #expect(o1 == "Office \(day) (1 book)", "Office backup independent of Home's: got \(o1)")

        // Unsafe characters are replaced; empty names fall back to the
        // date-only shape.
        let slashy = try BackupStore.save(data: data, bookCount: 1, libraryName: "A/B: C")
        #expect(slashy.hasPrefix("A-B- C "), "path separators sanitized: got \(slashy)")
        let blank = try BackupStore.save(data: data, bookCount: 0, libraryName: "   ")
        #expect(blank == "\(day) (0 books)", "blank library falls back to date-only: got \(blank)")

        // Long names are capped so rows stay readable.
        let long = try BackupStore.save(data: data, bookCount: 1, libraryName: String(repeating: "x", count: 60))
        #expect(long.hasPrefix(String(repeating: "x", count: 40) + " "), "long names capped at 40: got \(long)")
    }
}
