import CloudKit
import SwiftData
import XCTest
@testable import LibraryCove

/// Tests for the shared-library record codec and the mirror store's
/// change-detection / conflict state machine. All logic here is CloudKit-free
/// (codec tests use CKRecord locally, no network).
final class SharedLibraryTests: XCTestCase {

    // MARK: - Codec: record naming

    func testRecordNameRoundTrip() {
        let name = SharedLibraryRecord.recordName(type: .book, id: "ABC-123")
        XCTAssertEqual(name, "BNBook/ABC-123")
        XCTAssertEqual(SharedLibraryRecord.id(fromRecordName: name), "ABC-123")
    }

    func testRecordNameRejectsForeignTypes() {
        // CloudKit's own share/root records in a shared zone.
        XCTAssertNil(SharedLibraryRecord.RecordType(recordName: "cloudKit.share/xyz"))
        XCTAssertNil(SharedLibraryRecord.id(fromRecordName: "cloudKit.share/xyz"))
        XCTAssertNil(SharedLibraryRecord.id(fromRecordName: "TotallyUnrelated"))
    }

    // MARK: - Codec: payload round-trip

    func testBookRecordRoundTripPreservesFields() throws {
        var book = SharedBook(id: "book-1")
        book.title = "The Dispossessed"
        book.authors = ["Ursula K. Le Guin"]
        book.isbn = "9780061054884"
        book.publicationYear = 1974
        book.tags = ["sci-fi", "favorite"]
        book.kind = "fiction"
        book.shelves = ["Living room"]
        book.coverImageURL = "https://covers.example/x.jpg"
        book.coverFingerprint = "deadbeef"
        book.publisher = "Harper & Row"
        book.pageCount = 341
        book.bookDescription = "A wall."
        book.descriptionSource = "openlibrary"
        book.language = "en"
        book.physicalLocation = "Shelf 2"
        book.status = "completed"
        book.acquiredDate = Date(timeIntervalSince1970: 1_000_000)
        book.purchasePrice = 12.5
        book.rating = 5
        book.loanedTo = "Sam"
        book.loanedDate = Date(timeIntervalSince1970: 2_000_000)
        book.ownerID = "owner-1"
        book.sharedLibraryID = "lib-1"
        book.isPersonal = false
        book.createdAt = Date(timeIntervalSince1970: 500_000)
        book.updatedAt = Date(timeIntervalSince1970: 900_000)

        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "_creator")
        let record = SharedLibraryRecord.encode(book, coverData: nil, inZoneWith: zoneID)

        XCTAssertEqual(record.recordID.recordName, "BNBook/book-1")
        XCTAssertEqual(record.recordID.zoneID, zoneID)

        let change = SharedLibraryRecord.decode(record)
        guard case .book(let decoded) = change?.kind else {
            return XCTFail("decode should return a book change")
        }
        // Whole-second dates survive the millisecondsSince1970 round-trip
        // exactly, so strict Equatable equality holds.
        XCTAssertEqual(decoded, book)
    }

    func testNoteListAndItemRoundTrip() throws {
        var note = SharedNote(id: "note-1", bookID: "book-1", userID: "u1")
        note.content = "Brilliant"
        note.noteType = "quote"
        note.visibility = "shared"
        note.pageReference = "42"
        note.mentions = ["sam"]
        note.updatedAt = Date(timeIntervalSince1970: 3_000)

        var list = SharedReadingList(id: "list-1")
        list.name = "Summer"
        list.ownerID = "u1"
        list.isPrivate = false

        var item = SharedReadingListItem(id: "item-1", listID: "list-1", bookID: "book-1")
        item.position = 3
        item.priority = "high"
        item.targetDate = Date(timeIntervalSince1970: 4_000)

        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "_creator")
        let noteChange = SharedLibraryRecord.decode(SharedLibraryRecord.encode(note, inZoneWith: zoneID))
        let listChange = SharedLibraryRecord.decode(SharedLibraryRecord.encode(list, inZoneWith: zoneID))
        let itemChange = SharedLibraryRecord.decode(SharedLibraryRecord.encode(item, inZoneWith: zoneID))

        XCTAssertEqual(noteChange?.kind, .note(note))
        XCTAssertEqual(listChange?.kind, .readingList(list))
        XCTAssertEqual(itemChange?.kind, .readingListItem(item))
    }

    func testDecodeReturnsNilForForeignRecord() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "_creator")
        // CloudKit reserves the `cloudKit.share` record TYPE (constructing one
        // throws CKException), so the foreign-shape case is exercised via the
        // record NAME — decode must bail on names it can't parse.
        let record = CKRecord(recordType: "BNBook",
                              recordID: CKRecord.ID(recordName: "TotallyUnrelated/xyz", zoneID: zoneID))
        XCTAssertNil(SharedLibraryRecord.decode(record))
    }

    func testDecodeRejectsNewerSchemaVersion() {
        var book = SharedBook(id: "book-future")
        book.title = "From the future"
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "_creator")
        let record = SharedLibraryRecord.encode(book, coverData: nil, inZoneWith: zoneID)
        record[SharedLibraryRecord.Field.schema] = (SharedLibraryRecord.schemaVersion + 1) as NSNumber
        XCTAssertNil(SharedLibraryRecord.decode(record))
    }

    func testCoverAssetCarriesBytes() throws {
        var book = SharedBook(id: "book-asset")
        book.title = "Asset book"
        let bytes = Data("jpeg-bytes-here".utf8)
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "_creator")
        let record = SharedLibraryRecord.encode(book, coverData: bytes, inZoneWith: zoneID)
        XCTAssertEqual(SharedLibraryRecord.coverData(from: record), bytes)
        // No asset → nil, not an error.
        let bare = SharedLibraryRecord.encode(book, coverData: nil, inZoneWith: zoneID)
        XCTAssertNil(SharedLibraryRecord.coverData(from: bare))
        _ = book.coverFingerprint // silence unused warning in variants
    }

    // MARK: - Mirror: hash-index change detection

    @MainActor
    func testPushChangesDetectsNewChangedAndDeleted() throws {
        let mirror = SharedLibraryMirror()
        var index = SharedLibraryMirror.Index()

        let container = try ModelContainerForTesting.inMemory()
        let context = ModelContext(container)

        // First scan: one book — everything is "new".
        let book = Book(id: "b1", title: "First")
        book.libraryID = "test-library"
        context.insert(book)
        try context.save()
        var entries = mirror.scan(context: context)
        var changes = mirror.pushChanges(entries: entries, index: index)
        XCTAssertEqual(changes.count, 1)
        guard case .upsert(let firstEntry) = changes[0] else { return XCTFail("expected upsert") }
        XCTAssertEqual(firstEntry.recordName, "BNBook/b1")

        // Mark it synced.
        mirror.markSynced(entries: [firstEntry], failedRecordNames: [], index: &index)
        changes = mirror.pushChanges(entries: entries, index: index)
        XCTAssertTrue(changes.isEmpty, "clean record must not re-push")

        // Edit the book → dirty again.
        book.title = "First (annotated)"
        try context.save()
        entries = mirror.scan(context: context)
        changes = mirror.pushChanges(entries: entries, index: index)
        XCTAssertEqual(changes.count, 1, "edit must dirty the record")

        // Delete it → tombstone.
        context.delete(book)
        try context.save()
        entries = mirror.scan(context: context)
        changes = mirror.pushChanges(entries: entries, index: index)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0], .delete(recordName: "BNBook/b1"))
    }

    // MARK: - Mirror: conflict policy

    @MainActor
    func testApplyServerChangeToCleanRecordTakesServerCopy() throws {
        let mirror = SharedLibraryMirror()
        var index = SharedLibraryMirror.Index()
        let context = ModelContext(try ModelContainerForTesting.inMemory())

        // Server record for a book we don't have locally.
        var dto = SharedBook(id: "remote-1")
        dto.title = "Remote book"
        dto.updatedAt = Date(timeIntervalSince1970: 1_000)
        let applied = mirror.apply(changes: [SharedRecordChange(kind: .book(dto))],
                                   assets: [:], entriesByName: [:], index: &index, context: context)
        XCTAssertEqual(applied, 1)
        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.first?.title, "Remote book")
        XCTAssertEqual(index.hashes["BNBook/remote-1"],
                       SharedLibraryMirror.sha256(SharedLibraryMirror.payloadData(dto)))
    }

    @MainActor
    func testLocalDirtyNewerWinsOverServer() throws {
        let mirror = SharedLibraryMirror()
        var index = SharedLibraryMirror.Index()
        let context = ModelContext(try ModelContainerForTesting.inMemory())

        // Seed local book already synced with the cloud.
        let local = Book(id: "b9", title: "Local v1")
        local.libraryID = "test-library"
        local.updatedAt = Date(timeIntervalSince1970: 1_000)
        context.insert(local)
        try context.save()
        let entries = mirror.scan(context: context)
        mirror.markSynced(entries: entries, failedRecordNames: [], index: &index)

        // Local edit (dirty) with a NEWER updatedAt than the incoming server copy.
        local.title = "Local v2 (edited offline)"
        local.updatedAt = Date(timeIntervalSince1970: 5_000)
        try context.save()

        var incoming = SharedBook(id: "b9")
        incoming.title = "Server v0 (stale)"
        incoming.updatedAt = Date(timeIntervalSince1970: 2_000)

        let localEntries = Dictionary(mirror.scan(context: context).map { ($0.recordName, $0) },
                                      uniquingKeysWith: { f, _ in f })
        let applied = mirror.apply(changes: [SharedRecordChange(kind: .book(incoming))],
                                   assets: [:], entriesByName: localEntries,
                                   index: &index, context: context)
        XCTAssertEqual(applied, 0, "newer local edit must not be overwritten")
        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.first?.title, "Local v2 (edited offline)")
    }

    @MainActor
    func testServerNewerWinsOverDirtyLocal() throws {
        let mirror = SharedLibraryMirror()
        var index = SharedLibraryMirror.Index()
        let context = ModelContext(try ModelContainerForTesting.inMemory())

        let local = Book(id: "b10", title: "Local v1")
        local.libraryID = "test-library"
        local.updatedAt = Date(timeIntervalSince1970: 1_000)
        context.insert(local)
        try context.save()
        mirror.markSynced(entries: mirror.scan(context: context), failedRecordNames: [], index: &index)

        // Dirty local edit that is OLDER than what the server has.
        local.title = "Local stale edit"
        local.updatedAt = Date(timeIntervalSince1970: 1_500)
        try context.save()

        var incoming = SharedBook(id: "b10")
        incoming.title = "Server v2"
        incoming.updatedAt = Date(timeIntervalSince1970: 9_000)

        let localEntries = Dictionary(mirror.scan(context: context).map { ($0.recordName, $0) },
                                      uniquingKeysWith: { f, _ in f })
        let applied = mirror.apply(changes: [SharedRecordChange(kind: .book(incoming))],
                                   assets: [:], entriesByName: localEntries,
                                   index: &index, context: context)
        XCTAssertEqual(applied, 1, "server-newer copy replaces the dirty local state")
        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.first?.title, "Server v2")
    }

    @MainActor
    func testApplyDeleteRemovesRecordAndIndexEntry() throws {
        let mirror = SharedLibraryMirror()
        var index = SharedLibraryMirror.Index()
        let context = ModelContext(try ModelContainerForTesting.inMemory())

        let local = Book(id: "b11", title: "Doomed")
        local.libraryID = "test-library"
        context.insert(local)
        try context.save()
        mirror.markSynced(entries: mirror.scan(context: context), failedRecordNames: [], index: &index)
        XCTAssertNotNil(index.hashes["BNBook/b11"])

        let applied = mirror.apply(changes: [SharedRecordChange(kind: .deleted(recordName: "BNBook/b11"))],
                                   assets: [:], entriesByName: [:], index: &index, context: context)
        XCTAssertEqual(applied, 1)
        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertTrue(books.isEmpty)
        XCTAssertNil(index.hashes["BNBook/b11"])
    }

    @MainActor
    func testRelationshipsRepairAcrossBatchOrder() throws {
        let mirror = SharedLibraryMirror()
        var index = SharedLibraryMirror.Index()
        let context = ModelContext(try ModelContainerForTesting.inMemory())

        // Item arrives BEFORE its list and book (worst-case server order).
        var item = SharedReadingListItem(id: "i1", listID: "L1", bookID: "B1")
        item.position = 1
        var list = SharedReadingList(id: "L1")
        list.name = "Later list"
        list.ownerID = "u"
        var book = SharedBook(id: "B1")
        book.title = "Later book"

        // Reversed arrival: item, then list, then book — apply once.
        let applied = mirror.apply(changes: [
            SharedRecordChange(kind: .readingListItem(item)),
            SharedRecordChange(kind: .readingList(list)),
            SharedRecordChange(kind: .book(book)),
        ], assets: [:], entriesByName: [:], index: &index, context: context)
        XCTAssertEqual(applied, 3)

        let items = try context.fetch(FetchDescriptor<ReadingListItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertNotNil(items.first?.list, "list relationship must repair within one batch")
        XCTAssertNotNil(items.first?.book, "book relationship must repair within one batch")
        XCTAssertEqual(items.first?.list?.name, "Later list")
    }

    // MARK: - DTO conversion

    @MainActor
    func testBookDTOConversionKeepsSyncedFieldsAndStripsLocalCover() {
        let book = Book(id: "b12", title: "Converted")
        book.tags = ["x"]
        book.shelves = ["y"]
        book.coverImageURL = CoverImageStore.zipEntryName(forBookID: "b12") // local token
        let dto = SharedLibraryMirror.dto(from: book)
        XCTAssertNil(dto.coverImageURL, "local file tokens must not travel as URLs")
        XCTAssertEqual(dto.title, "Converted")
        XCTAssertEqual(dto.tags, ["x"])
        XCTAssertEqual(dto.shelves, ["y"])
        XCTAssertNil(dto.coverFingerprint, "no cover bytes → no fingerprint")
    }
}

/// Test helpers: an isolated in-memory-ish SwiftData container per test.
@MainActor
enum ModelContainerForTesting {
    static func inMemory() throws -> ModelContainer {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
