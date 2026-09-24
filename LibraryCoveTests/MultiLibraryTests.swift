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

    @Test func migrationOnEmptyStoreStaysLibraryLess() throws {
        wipe()
        let context = baseContext()
        // Fresh install / post-wipe: empty registry AND no content rows —
        // migration must NOT synthesize an "Untitled" default.
        LibraryScope.shared.migrateIfNeeded(context: context)
        #expect(LibraryScope.shared.all(context: context).isEmpty,
                "empty store stays library-less")
        #expect(LibraryScope.shared.active(context: context) == nil)
    }

    @Test func deletingLastLibraryLeavesRegistryEmpty() throws {
        wipe()
        let context = baseContext()
        LibraryScope.shared.migrateIfNeeded(context: context)
        let only = try LibraryScope.shared.create(name: "Only One", makeActive: true,
                                                  context: context)
        // Deleting the LAST library used to silently recreate an empty
        // "Untitled" default — the bug: Active Library showed a blank name
        // and the Libraries list said "Untitled".
        LibraryScope.shared.delete(only, context: context)
        #expect(LibraryScope.shared.all(context: context).isEmpty,
                "no phantom default after deleting the last library")
        #expect(LibraryScope.shared.active(context: context) == nil)
        #expect(LibraryScope.shared.activeID(context: context) == nil)
        #expect(LibraryScope.shared.activeName(context: context, memberName: "Matt") == nil)
    }

    @Test func deletingActiveLibraryPromotesOldestRemaining() throws {
        wipe()
        let context = baseContext()
        LibraryScope.shared.migrateIfNeeded(context: context)
        let first = try LibraryScope.shared.create(name: "First", makeActive: true,
                                                   context: context)
        _ = try LibraryScope.shared.create(name: "Second", makeActive: true,
                                           context: context)
        // Delete the ACTIVE one: the oldest remaining library promotes
        // (pre-existing behavior), NOT the no-library state.
        LibraryScope.shared.delete(first, context: context)
        let libs = LibraryScope.shared.all(context: context)
        #expect(libs.count == 1)
        #expect(libs.first?.id == LibraryScope.shared.activeID(context: context))
        #expect(libs.first?.isActive == true)
    }

    @Test func contentIsInvisibleAcrossLibraries() throws {
        wipe()
        let context = baseContext()
        LibraryScope.shared.migrateIfNeeded(context: context)
        if LibraryScope.shared.active(context: context) == nil {
            // Migration no longer synthesizes a default on an empty
            // registry — these tests exercise multi-library behavior, so
            // seed the fixed-id default explicitly.
            LibraryScope.shared.activate(
                LibraryInfo(id: LibraryScope.defaultLibraryID, name: "First",
                            isActive: true, createdAt: Date(), modifiedAt: Date()),
                context: context)
        }
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
        if LibraryScope.shared.active(context: context) == nil {
            // Migration no longer synthesizes a default on an empty
            // registry — these tests exercise multi-library behavior, so
            // seed the fixed-id default explicitly.
            LibraryScope.shared.activate(
                LibraryInfo(id: LibraryScope.defaultLibraryID, name: "First",
                            isActive: true, createdAt: Date(), modifiedAt: Date()),
                context: context)
        }
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
        if LibraryScope.shared.active(context: context) == nil {
            LibraryScope.shared.activate(
                LibraryInfo(id: LibraryScope.defaultLibraryID, name: "Active",
                            isActive: true, createdAt: Date(), modifiedAt: Date()),
                context: context)
        }
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

    /// The Settings "Delete Library" flow: content wipe + registry entry
    /// removal, so the deleted library disappears from the Libraries list.
    @Test func settingsDeleteRemovesActiveLibraryFromRegistry() throws {
        wipe()
        let context = baseContext()
        LibraryScope.shared.migrateIfNeeded(context: context)
        if LibraryScope.shared.active(context: context) == nil {
            // Migration no longer synthesizes a default on an empty
            // registry — these tests exercise multi-library behavior, so
            // seed the fixed-id default explicitly.
            LibraryScope.shared.activate(
                LibraryInfo(id: LibraryScope.defaultLibraryID, name: "First",
                            isActive: true, createdAt: Date(), modifiedAt: Date()),
                context: context)
        }
        let first = LibraryScope.shared.active(context: context)!
        let second = try LibraryScope.shared.create(name: "Second", makeActive: true, context: context)

        let secondBook = Book(id: "second-book", title: "Second", authors: [],
                              isbn: nil, ownerID: nil, createdAt: Date())
        secondBook.libraryID = second.id
        context.insert(secondBook)
        try context.save()

        // Mirror SettingsView.deleteLibraryData(): content first, then the
        // registry entry.
        _ = LibraryDataService.deleteActiveLibraryContent(context: context)
        LibraryScope.shared.delete(second, context: context)

        #expect(!LibraryScope.shared.all(context: context).contains { $0.id == second.id },
                "deleted library must disappear from the Libraries list")
        #expect(LibraryScope.shared.activeID(context: context) == first.id,
                "oldest remaining library becomes active")
        let visible = try context.fetch(LibraryScope.shared.activeBooksDescriptor(context: context))
        #expect(visible.isEmpty, "deleted library's content must be gone")
        // The remaining library's content is intact and visible after the switch.
        let firstBook = Book(id: "first-book", title: "First", authors: [],
                             isbn: nil, ownerID: nil, createdAt: Date())
        firstBook.libraryID = first.id
        context.insert(firstBook)
        try context.save()
        let visibleAfter = try context.fetch(LibraryScope.shared.activeBooksDescriptor(context: context))
        #expect(visibleAfter.count == 1 && visibleAfter.first?.id == "first-book")
    }

    /// Deleting the LAST library via the Settings flow: the registry goes
    /// EMPTY — no silently recreated "Untitled" default. The no-library
    /// state is explicit UI (Settings "Create Library", Library page
    /// no-library prompt); the user creates a library by name.
    @Test func settingsDeleteOfLastLibraryLeavesNoLibrary() throws {
        wipe()
        let context = baseContext()
        LibraryScope.shared.migrateIfNeeded(context: context)
        let second = try LibraryScope.shared.create(name: "Second", makeActive: true, context: context)

        let book = Book(id: "book", title: "T", authors: [],
                        isbn: nil, ownerID: nil, createdAt: Date())
        book.libraryID = second.id
        context.insert(book)
        try context.save()

        _ = LibraryDataService.deleteActiveLibraryContent(context: context)
        LibraryScope.shared.delete(second, context: context)

        let libraries = LibraryScope.shared.all(context: context)
        #expect(libraries.isEmpty, "no phantom default after the last delete, got \(libraries.count)")
        #expect(LibraryScope.shared.active(context: context) == nil)
        #expect(LibraryScope.shared.activeID(context: context) == nil)
        let visible = try context.fetch(LibraryScope.shared.activeBooksDescriptor(context: context))
        #expect(visible.isEmpty)
    }
}
