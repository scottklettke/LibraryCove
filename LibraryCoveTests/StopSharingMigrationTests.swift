import XCTest
import Testing
import SwiftData
@testable import LibraryCove

@Suite @MainActor struct StopSharingMigrationTests {
    /// Builds a mirror store at a temp URL with N books.
    private func makeMirrorStore(books: [Book], url: URL, libraryID: String? = nil) throws -> ModelContainer {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(schema: nil, url: url, allowsSave: true)])
        let context = ModelContext(container)
        for book in books {
            book.libraryID = libraryID
            context.insert(book)
        }
        try context.save()
        return container
    }

    @Test func mirrorStoreWithBooksExportsNonZero() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mirror-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // Mirror books carry the ACTIVE library id: in production the
        // mirror syncs the owner's personal books, which are tagged with
        // the active library. The JSON registry is global, so compute the
        // active id at test time. Migration no longer synthesizes a
        // default — create one explicitly with a fixed id for the tag.
        LibraryScope.shared.migrateIfNeeded(context: Persistence.inMemory.mainContext)
        if LibraryScope.shared.all(context: Persistence.inMemory.mainContext).isEmpty {
            LibraryScope.shared.activate(
                LibraryInfo(id: LibraryScope.defaultLibraryID, name: "Mirror Test",
                            isActive: true, createdAt: Date(), modifiedAt: Date()),
                context: Persistence.inMemory.mainContext)
        }
        let activeID = LibraryScope.shared.activeID(context: Persistence.inMemory.mainContext)
        let container = try makeMirrorStore(books: [
            Book(id: "b1", title: "Dune", authors: ["Frank Herbert"], isbn: "9780441172719"),
            Book(id: "b2", title: "Solaris", authors: ["Stanislaw Lem"]),
        ], url: url, libraryID: activeID)
        let context = ModelContext(container)
        let count = (try? context.fetchCount(FetchDescriptor<Book>())) ?? -1
        #expect(count == 2, "mirror should hold 2 books, got \(count)")

        let data = await LibraryDataService.export(context: context)
        #expect(data != nil, "export returned nil")
        if let data {
            let summary = try LibraryDataService.previewArchive(data: data)
            #expect(summary.books == 2, "previewArchive books = \(summary.books)")
        }
    }

    @Test func emptyMirrorExportsZeroBooks() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mirror-empty-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try makeMirrorStore(books: [], url: url)
        let context = ModelContext(container)
        let data = await LibraryDataService.export(context: context)
        #expect(data != nil)
        if let data {
            let summary = try LibraryDataService.previewArchive(data: data)
            #expect(summary.books == 0, "empty mirror should export 0 books, got \(summary.books)")
        }
    }

    @Test func mergeIntoPrivatePreservesExistingBooks() async throws {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let privateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-private-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: privateURL) }
        let privateContainer = try ModelContainer(for: schema,
                                                  configurations: [ModelConfiguration(schema: nil, url: privateURL, allowsSave: true)])
        let privateContext = ModelContext(privateContainer)
        privateContext.insert(Book(id: "own-1", title: "My Own Book", authors: ["Me"]))
        try privateContext.save()

        let mirrorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mirror-merge-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: mirrorURL) }
        LibraryScope.shared.migrateIfNeeded(context: Persistence.inMemory.mainContext)
        if LibraryScope.shared.all(context: Persistence.inMemory.mainContext).isEmpty {
            LibraryScope.shared.activate(
                LibraryInfo(id: LibraryScope.defaultLibraryID, name: "Mirror Test",
                            isActive: true, createdAt: Date(), modifiedAt: Date()),
                context: Persistence.inMemory.mainContext)
        }
        let mirrorActiveID = LibraryScope.shared.activeID(context: Persistence.inMemory.mainContext)
        let mirrorContainer = try makeMirrorStore(books: [
            Book(id: "mir-1", title: "Shared Book", authors: ["Someone"]),
        ], url: mirrorURL, libraryID: mirrorActiveID)
        let mirrorContext = ModelContext(mirrorContainer)

        guard let data = await LibraryDataService.export(context: mirrorContext) else {
            Issue.record("mirror export returned nil")
            return
        }
        try LibraryDataService.mergeArchive(data: data, context: privateContext)

        let titles = Set(((try? privateContext.fetch(FetchDescriptor<Book>())) ?? []).map(\.title))
        #expect(titles.contains("My Own Book"), "private book must survive merge")
        #expect(titles.contains("Shared Book"), "mirror book must be added")
    }
}

@Suite @MainActor struct ContainerReuseTests {
    /// Registry-level reuse guard: when the requested provider's store file
    /// is the LIVE container's file, makeContainer must hand back the live
    /// container instead of opening a second one (a second
    /// NSPersistentCloudKitContainer on the same file breaks CK mirroring).
    /// Installs its own container via swapShared — first-touch cannot be
    /// relied on, because the host app has usually opened Persistence.shared
    /// (cloud/nocloud store) before tests run.
    @Test func makeContainerReusesLiveStore() throws {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let localOnlyURL = try SyncStoreRegistry.provider(for: .localOnly)
            .makeStoreConfiguration().url
        // Host already live on that file → nothing to prove safely here
        // (installing would double-open); skip.
        if Persistence.liveStoreURL == localOnlyURL { return }

        let installed = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: nil, url: localOnlyURL, allowsSave: true)]
        )
        let original = Persistence.shared
        defer { Persistence.swapShared(to: original) }
        Persistence.swapShared(to: installed)

        let reused = SyncStoreRegistry.makeContainer(for: .localOnly)
        #expect(reused === installed,
                "makeContainer must reuse the live container for the same store file")
    }
}
