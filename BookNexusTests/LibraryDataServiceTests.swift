import Testing
import Foundation
import SwiftData
@testable import BookNexus

@Suite @MainActor struct LibraryDataServiceTests {

    /// Shared in-memory container. SwiftData fatals if a second in-memory
    /// container with the same model types is created in one process, so tests
    /// share `Persistence.inMemory` and reset it with `deleteAll` first.
    /// @MainActor serializes all tests, so the reset makes each fully isolated.
    private func baseContext() -> ModelContext {
        Persistence.inMemory.mainContext
    }

    /// A small but complete library exercising every entity type and every
    /// relationship (note->book, list items->list+book, connection book1/book2).
    private func seed(_ context: ModelContext) {
        let user = User(id: "u-1", email: "a@b.c", displayName: "Alex", isActive: true)
        context.insert(user)

        let b1 = Book(id: "b-1", title: "Dune", authors: ["Frank Herbert"], isbn: "9780441172719",
                      publicationYear: 1965, genres: ["Science Fiction"],
                      summary: "A classic summary of Dune.", rating: 5,
                      ownerID: "u-1", createdAt: Date(timeIntervalSince1970: 1000))
        let b2 = Book(id: "b-2", title: "Solaris", authors: ["Stanislaw Lem"],
                      genres: ["Science Fiction"], status: "to-read", ownerID: "u-1",
                      createdAt: Date(timeIntervalSince1970: 2000))
        context.insert(b1)
        context.insert(b2)

        let note = Note(id: "n-1", book: b1, userID: "u-1", content: "A classic.",
                        noteType: "general", createdAt: Date(timeIntervalSince1970: 1500))
        context.insert(note)

        let list = ReadingList(id: "l-1", name: "Favorites", ownerID: "u-1")
        context.insert(list)
        let item1 = ReadingListItem(id: "li-1", list: list, book: b1, position: 0)
        let item2 = ReadingListItem(id: "li-2", list: list, book: b2, position: 1)
        context.insert(item1)
        context.insert(item2)

        let conn = Connection(id: "c-1", book1: b1, book2: b2, connectionType: "similar_to",
                              connectionDescription: "Both about planets", createdByID: "u-1")
        context.insert(conn)

        try? context.save()
    }

    private func counts(_ context: ModelContext) -> [Int] {
        func c<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        }
        return [c(User.self), c(Book.self), c(Note.self),
                c(ReadingList.self), c(ReadingListItem.self), c(Connection.self)]
    }

    @Test func exportProducesReadableZip() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        seed(context)

        let zipData = try await #require(LibraryDataService.export(context: context))

        let files = try ZipArchive.unzip(zipData)
        #expect(files.keys.contains("library.json"))
        #expect(files.keys.contains("README-FORMAT.md"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ExportEnvelope.self, from: #require(files["library.json"]))
        #expect(envelope.format == "booknexus-library")
        #expect(envelope.version == 1)
        #expect(envelope.books.count == 2)
        #expect(envelope.notes.count == 1)
        #expect(envelope.readingLists.count == 1)
        #expect(envelope.readingListItems.count == 2)
        #expect(envelope.connections.count == 1)
        #expect(envelope.users.count == 1)

        // Relationship references are exported as ids (fetch order is not
        // guaranteed, so assert membership, not array position).
        #expect(envelope.notes.first?.bookID == "b-1")
        #expect(envelope.readingListItems.contains { $0.bookID == "b-1" })
        #expect(envelope.readingListItems.contains { $0.bookID == "b-2" })
        #expect(envelope.connections.first?.book1ID == "b-1")
        #expect(envelope.connections.first?.book2ID == "b-2")
        #expect(envelope.books.first { $0.id == "b-1" }?.rating == 5)
        #expect(envelope.books.first { $0.id == "b-1" }?.summary == "A classic summary of Dune.")
    }

    @Test func deleteAllClearsEverything() throws {
        let context = baseContext()
        // The suite shares one in-memory context, so reset it first (fixed
        // seed ids would collide with whatever a previous test left behind).
        LibraryDataService.deleteAll(context: context)
        seed(context)

        let removed = LibraryDataService.deleteAll(context: context)
        #expect(removed == 8) // 1 user + 2 books + 1 note + 1 list + 2 items + 1 connection

        #expect(counts(context) == [0, 0, 0, 0, 0, 0])
    }

    @Test func importRestoresEntireLibrary() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        seed(context)
        let zipData = try await #require(LibraryDataService.export(context: context))

        // Wipe, then restore from the export.
        LibraryDataService.deleteAll(context: context)
        let summary = try LibraryDataService.importArchive(data: zipData, context: context)
        #expect(summary.books == 2)
        #expect(summary.notes == 1)
        #expect(summary.readingLists == 1)
        #expect(summary.readingListItems == 2)
        #expect(summary.connections == 1)

        #expect(counts(context) == [1, 2, 1, 1, 2, 1])

        let books = try context.fetch(FetchDescriptor<Book>())
        let dune = books.first { $0.id == "b-1" }
        #expect(dune != nil)
        #expect(dune?.title == "Dune")
        #expect(dune?.rating == 5)
        #expect(dune?.summary == "A classic summary of Dune.")
        #expect(dune?.authors == ["Frank Herbert"])

        // Relationships are rewired to the restored records.
        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.first?.book?.id == "b-1")

        let items = try context.fetch(FetchDescriptor<ReadingListItem>())
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.list?.id == "l-1" })
        #expect(items.contains { $0.book?.id == "b-1" })
        #expect(items.contains { $0.book?.id == "b-2" })
        #expect(items.first { $0.position == 1 }?.book?.id == "b-2")

        let connections = try context.fetch(FetchDescriptor<Connection>())
        #expect(connections.first?.book1?.id == "b-1")
        #expect(connections.first?.book2?.id == "b-2")
        #expect(connections.first?.connectionDescription == "Both about planets")

        let users = try context.fetch(FetchDescriptor<User>())
        #expect(users.first?.displayName == "Alex")
    }

    @Test func previewDoesNotMutate() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        seed(context)
        let before = counts(context)
        let zipData = try await #require(LibraryDataService.export(context: context))

        let summary = try LibraryDataService.previewArchive(data: zipData)
        #expect(summary.books == 2)
        #expect(counts(context) == before)
    }

    @Test func importRejectsInvalidData() throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)

        // Not a zip.
        #expect(throws: LibraryDataError.self) {
            try LibraryDataService.previewArchive(data: Data("garbage".utf8))
        }

        // A valid zip but missing library.json.
        let wrongZip = try #require(ZipArchive.create(entries: [("other.txt", Data("hi".utf8))]))
        #expect(throws: LibraryDataError.self) {
            try LibraryDataService.previewArchive(data: wrongZip)
        }

        // Valid JSON but the wrong format marker.
        let fakeJSON = try #require(try? JSONEncoder().encode(["format": "not-booknexus"]))
        let fakeZip = try #require(ZipArchive.create(entries: [("library.json", fakeJSON)]))
        #expect(throws: LibraryDataError.self) {
            try LibraryDataService.previewArchive(data: fakeZip)
        }

        // Import into an existing library must be rejected without touching it.
        seed(context)
        #expect(counts(context) == [1, 2, 1, 1, 2, 1])
        #expect(throws: LibraryDataError.self) {
            try LibraryDataService.importArchive(data: wrongZip, context: context)
        }
        #expect(counts(context) == [1, 2, 1, 1, 2, 1])
    }

    @Test func zipWriterReaderRoundTrip() throws {
        let entries = [
            ("a.txt", Data("hello world hello world hello world".utf8)), // compressible
            ("b.json", Data(#"{"x": 1}"#.utf8)),                        // small
            ("empty.txt", Data()),                                        // empty (stored)
        ]
        let zipData = try #require(ZipArchive.create(entries: entries))
        let files = try ZipArchive.unzip(zipData)
        #expect(files["a.txt"] == Data("hello world hello world hello world".utf8))
        #expect(files["b.json"] == Data(#"{"x": 1}"#.utf8))
        #expect(files["empty.txt"] == Data())
    }

    /// Dumps the export zip to Documents so the host toolchain can verify it
    /// opens as a standard archive (`unzip` / Python `zipfile`).
    @Test func exportWritesStandardZipToDocuments() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        seed(context)
        let zipData = try await #require(LibraryDataService.export(context: context))
        let docs = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let url = docs.appendingPathComponent("export-check.zip")
        do {
            try zipData.write(to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
        } catch {
            Issue.record("could not write export file: \(error)")
        }
    }

    @Test func exportBundlesCoversAsJpegFiles() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)

        let remoteURL = "https://covers.openlibrary.org/b/id/123-L.jpg"
        let dataBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x44, 0x22])
        let dataCover = "data:image/jpeg;base64," + dataBytes.base64EncodedString()
        context.insert(Book(id: "b-cover-remote", title: "Remote", coverImageURL: remoteURL,
                            createdAt: Date(timeIntervalSince1970: 1000)))
        context.insert(Book(id: "b-cover-data", title: "Data", coverImageURL: dataCover,
                            createdAt: Date(timeIntervalSince1970: 2000)))
        // Two books sharing one remote URL: must fetch it exactly once.
        context.insert(Book(id: "b-cover-shared", title: "Shared", coverImageURL: remoteURL,
                            createdAt: Date(timeIntervalSince1970: 3000)))
        try context.save()

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        var fetchCount = 0
        let fetch: (URL) async -> Data? = { url in
            fetchCount += 1
            if url.absoluteString != remoteURL { Issue.record("unexpected fetch of \(url)") }
            return jpeg
        }
        let zipData = try await #require(LibraryDataService.export(context: context, fetchRemoteCover: fetch))
        #expect(fetchCount == 1) // deduped per distinct URL

        // Covers are bundled as separate JPEG files, not base64 in the JSON.
        let files = try ZipArchive.unzip(zipData)
        #expect(files["covers/b-cover-remote.jpg"] == jpeg)
        #expect(files["covers/b-cover-data.jpg"] == dataBytes)
        #expect(files["covers/b-cover-shared.jpg"] == jpeg)

        // They're also mirrored into the app filesystem store.
        #expect(CoverImageStore.data(forBookID: "b-cover-remote") == jpeg)
        #expect(CoverImageStore.data(forBookID: "b-cover-data") == dataBytes)

        // JSON stays readable: coverImageURL cleared, coverImageFile points at the entry.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ExportEnvelope.self, from: #require(files["library.json"]))
        for id in ["b-cover-remote", "b-cover-data", "b-cover-shared"] {
            #expect(envelope.books.first { $0.id == id }?.coverImageFile == "covers/\(id).jpg")
            #expect(envelope.books.first { $0.id == id }?.coverImageURL == nil)
        }

        // Importing rewrites covers to embedded data URLs (the synced form)
        // while still mirroring a copy into the filesystem store.
        LibraryDataService.deleteAll(context: context)
        _ = try LibraryDataService.importArchive(data: zipData, context: context)
        let restored = try context.fetch(FetchDescriptor<Book>())
        for id in ["b-cover-remote", "b-cover-data", "b-cover-shared"] {
            let book = restored.first { $0.id == id }
            #expect(book?.coverImageURL?.hasPrefix("data:image/jpeg;base64,") == true)
            #expect(CoverImageStore.data(forBookID: id) != nil)
        }
        // The embedded URL decodes back to the bundled JPEG bytes.
        let embedded = restored.first { $0.id == "b-cover-remote" }?.coverImageURL ?? ""
        #expect(CoverImageStore.data(fromDataURL: embedded) == files["covers/b-cover-remote.jpg"])
        #expect(files["covers/b-cover-remote.jpg"] == CoverImageStore.data(forBookID: "b-cover-remote"))
    }

    @Test func exportKeepsRemoteURLWhenCoverFetchFails() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        let remoteURL = "https://example.com/missing-cover.jpg"
        context.insert(Book(id: "b-nocover", title: "No cover", coverImageURL: remoteURL,
                            createdAt: Date(timeIntervalSince1970: 100)))
        try context.save()

        let fetch: (URL) async -> Data? = { _ in nil }
        let zipData = try await #require(LibraryDataService.export(context: context, fetchRemoteCover: fetch))
        let files = try ZipArchive.unzip(zipData)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ExportEnvelope.self, from: #require(files["library.json"]))
        #expect(envelope.books.first?.coverImageFile == nil)
        #expect(envelope.books.first?.coverImageURL == remoteURL)
        // No bundle entry when there's nothing to bundle.
        #expect(try ZipArchive.unzip(zipData)["covers/b-nocover.jpg"] == nil)
    }

    /// The old embedded-base64 format still imports: coverImageURL is a data URL.
    @Test func importAcceptsLegacyEmbeddedBase64Covers() throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        let dataCover = "data:image/jpeg;base64," + Data([0xFF, 0xD8]).base64EncodedString()
        let dto = BookDTO(model: Book(id: "b-legacy", title: "Legacy", coverImageURL: dataCover))
        let envelope = ExportEnvelope(format: LibraryDataService.formatMarker,
                                      version: LibraryDataService.version,
                                      exportedAt: Date(),
                                      users: [], books: [dto], notes: [],
                                      readingLists: [], readingListItems: [], connections: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let zipData = try #require(ZipArchive.create(entries: [
            ("library.json", try encoder.encode(envelope)),
            ("README-FORMAT.md", Data("dummy".utf8)),
        ]))

        _ = try LibraryDataService.importArchive(data: zipData, context: context)
        let restored = try context.fetch(FetchDescriptor<Book>())
        #expect(restored.first?.coverImageURL == dataCover)
    }

    @Test func mergeImportAddsOnlyNewBooks() throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)

        // Existing: one matched by ISBN, one by title+author (no ISBN).
        context.insert(Book(id: "x-1", title: "Dune", authors: ["Frank Herbert"],
                            isbn: "9780441172719", createdAt: Date(timeIntervalSince1970: 1)))
        context.insert(Book(id: "x-2", title: "Foundation", authors: ["Isaac Asimov"],
                            createdAt: Date(timeIntervalSince1970: 2)))
        try context.save()

        func dto(_ id: String, _ title: String, authors: [String], isbn: String?) -> BookDTO {
            BookDTO(model: Book(id: id, title: title, authors: authors, isbn: isbn,
                                createdAt: Date(timeIntervalSince1970: 5)))
        }
        let incoming = [
            dto("i-dup-isbn", "Dune", authors: ["Frank Herbert"], isbn: "9780441172719"),
            dto("i-dup-title", "Foundation", authors: ["Isaac Asimov"], isbn: nil),
            dto("i-new-1", "Hyperion", authors: ["Dan Simmons"], isbn: "9780553283686"),
            dto("i-new-2", "The Left Hand of Darkness", authors: ["Ursula K. Le Guin"], isbn: nil),
        ]
        let envelope = ExportEnvelope(format: LibraryDataService.formatMarker,
                                      version: LibraryDataService.version,
                                      exportedAt: Date(),
                                      users: [], books: incoming, notes: [],
                                      readingLists: [], readingListItems: [], connections: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let zipData = try #require(ZipArchive.create(entries: [
            ("library.json", try encoder.encode(envelope)),
            ("README-FORMAT.md", Data("dummy".utf8)),
        ]))

        let summary = try LibraryDataService.mergeArchive(data: zipData, context: context)
        #expect(summary.books == 2)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 4) // 2 existing + 2 new
        #expect(books.contains { $0.id == "i-new-1" })
        #expect(books.contains { $0.id == "i-new-2" })
        #expect(!books.contains { $0.id == "i-dup-isbn" })
        #expect(!books.contains { $0.id == "i-dup-title" })
        #expect(books.contains { $0.id == "x-1" }) // existing untouched
        #expect(books.contains { $0.id == "x-2" })
    }

    @Test func materializeLocalCoversEmbedsBytesForSync() throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)

        let id = UUID().uuidString
        let bytes = Data([0xFF, 0xD8, 0x01, 0x02, 0x03])
        // A legacy file-token cover (what older versions stored in the DB).
        context.insert(Book(id: id, title: "Old", coverImageURL: CoverImageStore.zipEntryName(forBookID: id)))
        try context.save()
        #expect(CoverImageStore.save(bytes, forBookID: id))

        LibraryDataService.materializeLocalCovers(context: context)

        let book = try #require(context.fetch(FetchDescriptor<Book>()).first)
        #expect(book.coverImageURL?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(CoverImageStore.data(fromDataURL: book.coverImageURL ?? "") == bytes)
    }

    @Test func mergeRecognizesDashEquivalentISBN() throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        // Stored canonical form (no dashes).
        context.insert(Book(id: "x-1", title: "Dune", authors: ["Frank Herbert"],
                            isbn: "9780441172719", createdAt: Date(timeIntervalSince1970: 1)))
        try context.save()

        // Incoming uses the same ISBN written with dashes/spaces.
        let dune = BookDTO(model: Book(id: "i-dup", title: "Dune", authors: ["Frank Herbert"],
                                       isbn: "978-0-441-17271-9",
                                       createdAt: Date(timeIntervalSince1970: 5)))
        let envelope = ExportEnvelope(format: LibraryDataService.formatMarker,
                                      version: LibraryDataService.version,
                                      exportedAt: Date(),
                                      users: [], books: [dune], notes: [],
                                      readingLists: [], readingListItems: [], connections: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let zipData = try #require(ZipArchive.create(entries: [
            ("library.json", try encoder.encode(envelope)),
            ("README-FORMAT.md", Data("dummy".utf8)),
        ]))

        let summary = try LibraryDataService.mergeArchive(data: zipData, context: context)
        #expect(summary.books == 0) // the dashed ISBN is the same book
        #expect((try context.fetchCount(FetchDescriptor<Book>())) == 1)
    }

    @Test func mergeCandidatesListsOnlyNewBooks() throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        context.insert(Book(id: "x-1", title: "Dune", authors: ["Frank Herbert"],
                            isbn: "9780441172719", createdAt: Date(timeIntervalSince1970: 1)))
        context.insert(Book(id: "x-2", title: "Foundation", authors: ["Isaac Asimov"],
                            createdAt: Date(timeIntervalSince1970: 2)))
        try context.save()

        func dto(_ id: String, _ title: String, authors: [String], isbn: String?) -> BookDTO {
            BookDTO(model: Book(id: id, title: title, authors: authors, isbn: isbn,
                                createdAt: Date(timeIntervalSince1970: 5)))
        }
        let incoming = [
            dto("i-dup-isbn", "Dune", authors: ["Frank Herbert"], isbn: "9780441172719"),
            dto("i-dup-title", "Foundation", authors: ["Isaac Asimov"], isbn: nil),
            dto("i-new-1", "Hyperion", authors: ["Dan Simmons"], isbn: "9780553283686"),
            dto("i-new-2", "The Left Hand of Darkness", authors: ["Ursula K. Le Guin"], isbn: nil),
        ]
        let envelope = ExportEnvelope(format: LibraryDataService.formatMarker,
                                      version: LibraryDataService.version,
                                      exportedAt: Date(),
                                      users: [], books: incoming, notes: [],
                                      readingLists: [], readingListItems: [], connections: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let zipData = try #require(ZipArchive.create(entries: [
            ("library.json", try encoder.encode(envelope)),
            ("README-FORMAT.md", Data("dummy".utf8)),
        ]))

        let candidates = try LibraryDataService.mergeCandidates(data: zipData, context: context)
        #expect(candidates.map(\.id) == ["i-new-1", "i-new-2"]) // in archive order
        // Non-mutating: current library untouched.
        #expect((try context.fetchCount(FetchDescriptor<Book>())) == 2)
    }
}

@Suite struct CoverImageStoreTests {

    @Test func tokenResolvesBackToStoredFile() {
        let id = UUID().uuidString
        let data = Data([0xFF, 0xD8, 0x01, 0x02, 0x03])
        #expect(CoverImageStore.save(data, forBookID: id))

        let token = CoverImageStore.zipEntryName(forBookID: id)
        #expect(token.hasPrefix("covers/"))
        // The stored reference token resolves to image bytes and a real file.
        #expect(CoverImageStore.localData(forCover: token) == data)
        #expect(CoverImageStore.displayURL(forCover: token)?.isFileURL == true)
    }

    @Test func staleAbsolutePathRescuedByFilename() {
        let id = UUID().uuidString
        let data = Data([0xFF, 0xD8, 0x11, 0x22, 0x33])
        #expect(CoverImageStore.save(data, forBookID: id))

        // An absolute path from an older install whose container no longer
        // exists but whose filename matches the store's layout.
        let stale = "file:///OldContainer-UUID/\(CoverImageStore.zipEntryName(forBookID: id))"
        #expect(CoverImageStore.localData(forCover: stale) == data)
        #expect(CoverImageStore.displayURL(forCover: stale) != nil)
    }

    @Test func remoteAndDataReferencesUnaffected() {
        #expect(CoverImageStore.localData(forCover: "https://example.com/c.jpg") == nil)
        let bytes = Data([0xFF, 0xD8, 0x99])
        let dataURL = "data:image/jpeg;base64," + bytes.base64EncodedString()
        #expect(CoverImageStore.localData(forCover: dataURL) == bytes)
    }

    @Test func manualStubKeepsISBNForHandEntry() {
        let stub = CatalogBook.manualStub(isbn: "978-1-23456-789-0")
        #expect(stub.isbn == "9781234567890") // normalized, no dashes
        #expect(stub.title.isEmpty)           // must be typed by hand
        #expect(stub.authors.isEmpty)
        #expect(stub.id == "isbn-9781234567890")
    }
}
