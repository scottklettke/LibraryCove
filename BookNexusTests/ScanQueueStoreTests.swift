import Testing
import Foundation
@testable import BookNexus

/// Deterministic catalog stub for queue tests. Returns the canned result or
/// throws exactly as instructed, so state transitions are fully scriptable.
/// `@unchecked Sendable` is intentional: instances are only ever used on the
/// main actor (the store is `@MainActor`), so the closure needs no extra
/// isolation and may freely capture suite-scoped values.
final class MockCatalog: CatalogService, @unchecked Sendable {
    var lookupHandler: (String) async throws -> CatalogBook?
    init(_ handler: @escaping (String) async throws -> CatalogBook? = { _ in nil }) {
        self.lookupHandler = handler
    }
    func search(query: String, preferred: DescriptionSource) async throws -> [CatalogBook] { [] }
    func lookup(isbn: String, preferred: DescriptionSource) async throws -> CatalogBook? {
        try await lookupHandler(isbn)
    }
}

/// File scope (nonisolated) so it can be called freely from test closures.
private func testBook(isbn: String, title: String = "Dune") -> CatalogBook {
    CatalogBook(id: "isbn-\(isbn)", title: title, authors: ["Frank Herbert"],
                isbn: isbn, publicationYear: 1965, tags: ["Science Fiction"],
                publisher: "Chilton", pageCount: 412, description: "Classic.",
                language: "en", coverURLs: [], descriptionSource: "test", source: "test")
}

/// The background scan queue: instant ISBN caching, offline-crash-safe
/// persistence, and status transitions driven by a background processor.
@Suite @MainActor
struct ScanQueueStoreTests {
    private let defaults: UserDefaults
    private let catalog: MockCatalog
    private let suiteName: String

    init() {
        suiteName = "ScanQueueStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        catalog = MockCatalog { isbn in testBook(isbn: isbn) }
    }

    // Every @Test gets its own instance; the domain is avoided/superseded by
    // a unique suite name, so nothing leaks between tests.

    private func makeStore(autoProcess: Bool = false) -> ScanQueueStore {
        ScanQueueStore(defaults: defaults, catalog: catalog, autoProcess: autoProcess)
    }

    @Test func enqueueNormalizesAndDeduplicates() {
        let store = makeStore()
        #expect(store.enqueue(isbn: "978-0-441-17271-9") == .queued)
        #expect(store.enqueue(isbn: "9780441172719") == .duplicateInQueue)
        #expect(store.count == 1)
        #expect(store.items[0].isbn == "9780441172719")
        #expect(store.items[0].status == .queued)
    }

    @Test func invalidISBNNotQueued() {
        let store = makeStore()
        #expect(store.enqueue(isbn: "   ") == .invalid)
        #expect(store.count == 0)
    }

    @Test func processorResolvesAQueuedIsbn() async throws {
        let store = makeStore()
        catalog.lookupHandler = { isbn in testBook(isbn: isbn, title: "Testament of Youth") }
        store.enqueue(isbn: "9780140328721")
        await store.drain()

        #expect(store.items.count == 1)
        #expect(store.items[0].status == .ready)
        #expect(store.items[0].book?.title == "Testament of Youth")
        #expect(store.items[0].error == nil)
    }

    @Test func nilLookupBecomesManualStub() async {
        catalog.lookupHandler = { _ in nil }
        let store = makeStore()
        store.enqueue(isbn: "9780000000001")
        await store.drain()

        #expect(store.items[0].status == .unavailable)
        #expect(store.items[0].book?.title == "")
        #expect(store.items[0].book?.source == "manual")
        #expect(store.items[0].book?.isbn == "9780000000001")
        #expect(store.hasImportable == true, "manual stub is still importable")
    }

    @Test func throwingLookupBecomesFailedAndRetryResolves() async {
        let store = makeStore()
        var attempts = 0
        catalog.lookupHandler = { isbn in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return testBook(isbn: isbn)
        }
        store.enqueue(isbn: "9780140328721")
        await store.drain()

        #expect(store.items[0].status == .failed)
        #expect(store.items[0].book == nil)
        #expect(store.items[0].error != nil)
        #expect(store.hasImportable == false)

        store.retry(id: store.items[0].id)
        await store.drain()

        #expect(store.items[0].status == .ready)
        #expect(store.items[0].book?.title == "Dune")
        #expect(store.items[0].error == nil)
    }

    @Test func crashDuringProcessingResumesAsQueuedAndRetriesFailures() async {
        // Simulate a force-quit mid-lookup (item persisted as .processing) and
        // a previous session's network failure (.failed). A fresh launch must
        // retry both — nothing is permanently stuck.
        let processing = ScanQueueItem(id: "isbn-1111111111", isbn: "1111111111",
                                       status: .processing, book: nil,
                                       enqueuedAt: Date(timeIntervalSince1970: 1000), error: nil)
        let failed = ScanQueueItem(id: "isbn-2222222222", isbn: "2222222222",
                                   status: .failed, book: nil,
                                   enqueuedAt: Date(timeIntervalSince1970: 2000), error: "boom")
        let data = try! JSONEncoder().encode([processing, failed])
        defaults.set(data, forKey: "scanQueueItems")

        let store = makeStore()
        #expect(Set(store.items.map { $0.status }) == [.queued],
                "in-flight/failed items must restart as queued on launch")

        catalog.lookupHandler = { isbn in testBook(isbn: isbn) }
        await store.drain()
        #expect(store.items.allSatisfy { $0.status == .ready })
    }

    @Test func removeDropsAndPersists() async {
        catalog.lookupHandler = { isbn in testBook(isbn: isbn) }
        let store = makeStore()
        store.enqueue(isbn: "9780140328721")
        await store.drain()
        let id = store.items[0].id
        store.remove(id: id)
        #expect(store.count == 0)

        let reloaded = makeStore()
        #expect(reloaded.count == 0)
    }

    @Test func persistenceSurvivesStoreRecreation() async {
        catalog.lookupHandler = { isbn in testBook(isbn: isbn) }
        let store = makeStore()
        store.enqueue(isbn: "9780140328721")
        await store.drain()

        let reloaded = makeStore()
        #expect(reloaded.count == 1)
        #expect(reloaded.items[0].status == .ready)
        #expect(reloaded.items[0].book?.id == store.items[0].book?.id)
    }

    @Test func legacyPendingScansMigrateIntoQueue() {
        // Pre-queue builds persisted raw CatalogBooks under the old key.
        let data = try! JSONEncoder().encode([testBook(isbn: "9780140328721")])
        defaults.set(data, forKey: "pendingScannedBooks")

        let store = makeStore()
        #expect(store.items.count == 1)
        #expect(store.items[0].status == .ready)
        #expect(store.items[0].isbn == "9780140328721")
        // The legacy key is consumed.
        #expect(defaults.data(forKey: "pendingScannedBooks") == nil)
    }

    @Test func importableBooksPreserveScanOrder() async {
        catalog.lookupHandler = { isbn in testBook(isbn: isbn, title: "B-\(isbn)") }
        let store = makeStore()
        store.enqueue(isbn: "9780000000001")
        store.enqueue(isbn: "9780000000002")
        await store.drain()

        #expect(store.importableBooks.map { $0.isbn } == ["9780000000001", "9780000000002"])
    }

    @Test func duplicateScanMidProcessingNotRebilledAsNew() {
        catalog.lookupHandler = { isbn in testBook(isbn: isbn) }
        let store = makeStore(autoProcess: true)
        store.enqueue(isbn: "9780140328721")
        #expect(store.count == 1)
        #expect(store.enqueue(isbn: "9780140328721") == .duplicateInQueue)
        #expect(store.count == 1)
    }

    /// Regression for the reported "stuck looking up" bug: the background
    /// processor (the prod path: `autoProcess: true`) must resolve queued
    /// ISBNs. The broken build set `isProcessing` eagerly in
    /// `startProcessingIfNeeded`, which made the scheduled `drain()` no-op and
    /// left every scanned item spinning at `.queued` forever. Existing drain
    /// tests were immune because they call `drain()` directly with
    /// `autoProcess: false`.
    @Test func autoProcessBackgroundTaskResolvesQueuedIsbn() async {
        catalog.lookupHandler = { isbn in testBook(isbn: isbn) }
        let store = makeStore(autoProcess: true)
        let id = "isbn-9780140328721"
        store.enqueue(isbn: "9780140328721")

        // Give the scheduled background task a bounded window to run. The test
        // suspends (Task.sleep) so the main-actor processor can make progress;
        // with the regression it never leaves queued/processing and fails.
        var attempts = 0
        while attempts < 500 {
            if let item = store.item(id: id),
               item.status != .queued, item.status != .processing { break }
            try? await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(store.item(id: id)?.status == .ready)
        #expect(store.item(id: id)?.book?.id == id)
    }
}
