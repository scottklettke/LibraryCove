import Testing
import Foundation
import SwiftData
@testable import LibraryCove

/// Multi-library foundation: launch migration tags legacy rows into the
/// default library; content is invisible across libraries.
@Suite(.serialized) @MainActor struct MultiLibraryTests {

    private func baseContext() -> ModelContext {
        Persistence.inMemory.mainContext
    }

    private func wipe() {
        // Fresh in-memory container starts empty; clear rows that earlier
        // tests in this suite may have created (User, Book...) plus the
        // JSON registry (persisted to Application Support).
        try? FileManager.default.removeItem(at: LibraryScope.shared.registryURLForTesting)
        try? Persistence.inMemory.mainContext.delete(model: User.self)
        try? Persistence.inMemory.mainContext.delete(model: Book.self)
        try? Persistence.inMemory.mainContext.delete(model: Note.self)
        try? Persistence.inMemory.mainContext.delete(model: ReadingList.self)
        try? Persistence.inMemory.mainContext.delete(model: ReadingListItem.self)
        try? Persistence.inMemory.mainContext.delete(model: Connection.self)
    }

    @Test func migrationTagsLegacyRowsIntoDefaultLibrary() throws {
        wipe()
        let context = baseContext()
        // Legacy era: books with libraryID == nil, no Library rows at all.
        let legacy = Book(id: "legacy-1", title: "Legacy Book", authors: ["L. Gacy"],
                          isbn: nil, ownerID: nil,
                          createdAt: Date(timeIntervalSince1970: 1000))
        legacy.libraryID = nil
        context.insert(legacy)
        try context.save()

        LibraryScope.shared.migrateIfNeeded(context: context)

        let libraries = LibraryScope.shared.all(context: context)
        #expect(libraries.count == 1, "migration creates exactly one default library, got \(libraries.count)")
        #expect(libraries.first?.id == LibraryScope.defaultLibraryID)
        #expect(libraries.first?.isActive == true)

        let fetched = try context.fetch(FetchDescriptor<Book>())
        #expect(fetched.first?.libraryID == LibraryScope.defaultLibraryID,
                "legacy row must be tagged into the default library")
    }

    @Test func contentIsInvisibleAcrossLibraries() throws {
        wipe()
        let context = baseContext()
        LibraryScope.shared.migrateIfNeeded(context: context)
        let first = LibraryScope.shared.active(context: context)!

        // Second library, active (the switch).
        let second = try LibraryScope.shared.create(name: "Second", makeActive: true, context: context)
        #expect(LibraryScope.shared.activeID(context: context) == second.id)

        // A book in the FIRST library (created before the switch).
        let firstBook = Book(id: "first-book", title: "First Library Book",
                             authors: ["A. Uthor"], isbn: nil, ownerID: nil,
                             createdAt: Date())
        firstBook.libraryID = first.id
        context.insert(firstBook)
        try context.save()

        // Active-library descriptor must NOT return the first library's book.
        let visible = try context.fetch(LibraryScope.shared.activeBooksDescriptor(context: context))
        #expect(visible.isEmpty, "other libraries' books must be invisible, got \(visible.count)")

        // Switch back: the first library's book becomes visible again.
        LibraryScope.shared.activate(first, context: context)
        let visibleAfterSwitch = try context.fetch(LibraryScope.shared.activeBooksDescriptor(context: context))
        #expect(visibleAfterSwitch.count == 1)
        #expect(visibleAfterSwitch.first?.id == "first-book")
    }

    @Test func deletingLibraryRemovesOnlyItsContent() throws {
        wipe()
        let context = baseContext()
        LibraryScope.shared.migrateIfNeeded(context: context)
        let first = LibraryScope.shared.active(context: context)!
        let second = try LibraryScope.shared.create(name: "Second", makeActive: false, context: context)

        let firstBook = Book(id: "first-book", title: "First", authors: [],
                             isbn: nil, ownerID: nil, createdAt: Date())
        firstBook.libraryID = first.id
        context.insert(firstBook)
        let secondBook = Book(id: "second-book", title: "Second", authors: [],
                              isbn: nil, ownerID: nil, createdAt: Date())
        secondBook.libraryID = second.id
        context.insert(secondBook)
        try context.save()

        // Delete the NON-active second library.
        LibraryScope.shared.delete(second, context: context)

        let rows = try context.fetch(FetchDescriptor<Book>())
        #expect(rows.count == 1 && rows.first?.id == "first-book",
                "only the deleted library's content is removed")
        #expect(LibraryScope.shared.all(context: context).count == 1)
        #expect(LibraryScope.shared.activeID(context: context) == first.id,
                "active library is untouched by another library's deletion")
    }

    @Test func replaceImportTargetsActiveLibraryOnly() async throws {
        wipe()
        let context = baseContext()
        LibraryScope.shared.migrateIfNeeded(context: context)
        let active = LibraryScope.shared.active(context: context)!
        let other = try LibraryScope.shared.create(name: "Other", makeActive: false, context: context)

        let otherBook = Book(id: "other-book", title: "Other's Book", authors: [],
                             isbn: nil, ownerID: nil, createdAt: Date())
        otherBook.libraryID = other.id
        context.insert(otherBook)
        let activeBook = Book(id: "active-book", title: "Active's Book", authors: [],
                              isbn: nil, ownerID: nil, createdAt: Date())
        activeBook.libraryID = active.id
        context.insert(activeBook)
        try context.save()

        // Build a tiny archive (export the active library), then
        // replace-import it — the OTHER library's book must survive.
        guard let zip = await LibraryDataService.export(context: context) else {
            Issue.record("export failed"); return
        }
        _ = try LibraryDataService.importArchive(data: zip, context: context)

        let rows = try context.fetch(FetchDescriptor<Book>())
        let otherRows = rows.filter { $0.libraryID == other.id }
        #expect(!otherRows.isEmpty, "other libraries' books must survive a replace-import into the active library")
    }
}
