import Testing
import Foundation
import SwiftData
@testable import LibraryCove

/// Throwaway verification for the duplicates-preserved pipeline:
/// export → restore (importArchive) → export must keep same-title copies.
@Suite(.serialized) @MainActor struct DuplicatePreservationTests {

    private func baseContext() -> ModelContext {
        Persistence.inMemory.mainContext
    }

    @Test func exportImportExportPreservesDuplicates() async throws {
        let context = baseContext()

        // Mirror the real app: launch migration creates the default
        // library and tags legacy (libraryID == nil) rows into it. Other
        // suites may have left other libraries in the shared registry, so
        // make the DEFAULT library the active one explicitly.
        LibraryScope.shared.migrateIfNeeded(context: context)
        if let defaultLibrary = LibraryScope.shared.all(context: context)
            .first(where: { $0.id == LibraryScope.defaultLibraryID }) {
            LibraryScope.shared.activate(defaultLibrary, context: context)
        } else {
            _ = try LibraryScope.shared.create(name: "Default", makeActive: true, context: context)
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
        let name = try BackupStore.save(data: zip1, bookCount: 2)
        defer { BackupStore.deleteAll() }
        let items = BackupStore.list()
        #expect(items.contains { $0.name == name })
        let storedData = try Data(contentsOf: items.first { $0.name == name }!.url)
        let back1 = try LibraryDataService.archiveBooks(data: storedData)
        #expect(back1.count == 2, "backup zip must contain BOTH copies, got \(back1.count)")

        // 2) Replace-restore path: importArchive into a wiped store.
        LibraryDataService.deleteAll(context: context)
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
}
