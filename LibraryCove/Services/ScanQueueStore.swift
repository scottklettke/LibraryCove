import Foundation
import Observation

/// What happens to a queued ISBN after its worker attempted a lookup.
enum ScanItemStatus: String, Codable, Equatable {
    /// ISBN cached from the camera; lookup not started yet.
    case queued
    /// A lookup is currently in flight for this ISBN.
    case processing
    /// Lookup succeeded — `book` has a title and can be imported.
    case ready
    /// Lookup finished but no catalog record exists — `book` is a manual stub
    /// the user fills in by hand.
    case unavailable
    /// Lookup threw (network/server) — retryable; retried on next launch.
    case failed
}

/// A scanned-but-not-yet-added book. The ISBN is cached the instant the camera
/// sees it; the background processor fills in `book` as lookups complete, so
/// the user can scan many books quickly without waiting on the network.
struct ScanQueueItem: Identifiable, Equatable, Codable {
    /// `isbn-<normalized>` — identical to the `CatalogBook.id` a lookup
    /// produces, so operations keyed on either value resolve the same item.
    let id: String
    let isbn: String
    var status: ScanItemStatus
    /// Populated once processing resolves the ISBN.
    var book: CatalogBook?
    let enqueuedAt: Date
    var error: String?
}

enum ScanQueueEnqueueResult {
    case queued
    case duplicateInQueue
    case invalid
}

/// Crash-safe queue of scanned ISBNs. Camera scans enqueue immediately; a
/// background processor resolves each ISBN via `CatalogService` and persists
/// every state change so a crash mid-scan never loses the user's place. All
/// state is main-actor isolated; network work suspends off the main thread.
@MainActor
final class ScanQueueStore: ObservableObject {
    static let shared = ScanQueueStore()

    @Published private(set) var items: [ScanQueueItem] = []
    @Published private(set) var isProcessing = false

    private let defaults: UserDefaults
    private let autoProcess: Bool
    private var catalog: CatalogService
    private var processor: Task<Void, Never>?
    /// Wall-clock cap per lookup; injectable so tests can drive the timeout
    /// path fast instead of waiting out the production 30s.
    private let lookupDeadline: TimeInterval

    private static let key = "scanQueueItems"
    private static let legacyKey = "pendingScannedBooks"
    init(defaults: UserDefaults = .standard,
         catalog: CatalogService = OpenLibraryService(),
         autoProcess: Bool = true,
         lookupDeadline: TimeInterval = 30) {
        self.defaults = defaults
        self.catalog = catalog
        self.autoProcess = autoProcess
        self.lookupDeadline = lookupDeadline
        self.items = Self.load(from: defaults)
    }

    var count: Int { items.count }

    /// Books ready to import, in scan order.
    var importableBooks: [CatalogBook] {
        items.filter { $0.book != nil }.compactMap { $0.book }
    }

    var hasImportable: Bool { importableBooks.isEmpty == false }

    func item(id: String) -> ScanQueueItem? {
        items.first { $0.id == id }
    }

    /// Cache an ISBN the moment the camera sees it. Does no network work and
    /// never blocks scanning. Returns how the scan was handled.
    @discardableResult
    func enqueue(isbn: String) -> ScanQueueEnqueueResult {
        guard let normalized = Book.normalizedISBN(isbn) else { return .invalid }
        let id = "isbn-\(normalized)"
        guard item(id: id) == nil else { return .duplicateInQueue }
        let item = ScanQueueItem(id: id, isbn: normalized, status: .queued,
                                 book: nil, enqueuedAt: Date(), error: nil)
        items.append(item)
        persist()
        startProcessingIfNeeded()
        return .queued
    }

    /// Reprocess a failed ISBN (user-triggered retry).
    func retry(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].status != .ready, items[idx].status != .unavailable else { return }
        items[idx].status = .queued
        items[idx].book = nil
        items[idx].error = nil
        persist()
        startProcessingIfNeeded()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Drops every queued/resolved scan whose ISBN normalizes to `isbn`.
    /// The duplicate-scan alert uses this to make its OK action honor the
    /// "skip this scan" promise: a stale entry for a book already in the
    /// library (an earlier scan that was never added) must not linger in the
    /// pending list.
    func removeISBN(_ isbn: String) {
        guard let normalized = Book.normalizedISBN(isbn) else { return }
        items.removeAll { $0.id == "isbn-\(normalized)" }
        persist()
    }

    /// Used by the "Delete all data" reset and UI-test hygiene. When a UI-test
    /// seed is present it is authoritative and re-applied (mirroring the old
    /// store, which re-read the launch environment at every display).
    func clear() {
        if let seeded = Self.environmentSeed() {
            items = seeded
            persist()
            return
        }
        items = []
        persist()
    }

    /// Replaces the queue wholesale. Used by the UI-test seam that seeds
    /// already-looked-up books (`UI_TEST_SCANNED_BOOKS`).
    func replaceAll(with books: [CatalogBook]) {
        items = books.map {
            ScanQueueItem(id: $0.id, isbn: $0.isbn ?? "", status: .ready,
                          book: $0, enqueuedAt: Date(), error: nil)
        }
        persist()
    }

    /// Idempotent kick-off: processes every queued ISBN in scan order on a
    /// background task. Safe to call anytime; a running processor is reused.
    /// Returns the spawned task (nil when nothing was started) so callers that
    /// need to await the background path deterministically can do so.
    @discardableResult
    func startProcessingIfNeeded() -> Task<Void, Never>? {
        // Tests drive `drain()` directly and pass autoProcess: false so an
        // unscheduled background task never races their awaited processing.
        guard autoProcess else { return nil }
        let hasQueued = items.contains { $0.status == .queued }
        guard hasQueued, processor == nil else { return nil }
        // Do NOT set `isProcessing` here: the task is scheduled (not yet run),
        // so an eager flag would make its own `drain()` no-op and leave items
        // queued forever. `drain()` owns the flag for the duration it runs.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drain()
            self.isProcessing = false
            self.processor = nil
        }
        processor = task
        return task
    }

    /// Processes queued items with bounded concurrency — up to 3 catalog
    /// lookups in flight — so scanning a stack of books doesn't serialize one
    /// network round-trip behind the next. `items` itself never reorders
    /// (`update` mutates in place), so `importableBooks` keeps scan order.
    /// Awaitable so tests run deterministically: it returns only after every
    /// queued item reached a terminal state. Reentrant-safe: while a drain is
    /// in flight (`isProcessing` true), a concurrent caller returns
    /// immediately — the running drain re-checks for newly queued items after
    /// every batch, so nothing is left behind.
    func drain() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        let maxInFlight = 3
        while !Task.isCancelled {
            // Snapshot the queued ids each pass; `process` re-validates
            // status on the main actor, so items enqueued (or removed) mid-
            // drain are picked up by later passes exactly once.
            let batch = items.filter { $0.status == .queued }.prefix(maxInFlight).map(\.id)
            guard !batch.isEmpty else { break }
            await withTaskGroup(of: Void.self) { group in
                for id in batch {
                    group.addTask { await self.process(id) }
                }
                await group.waitForAll()
            }
        }
    }

    /// Lookup outcome, so a thrown error keeps its text for the retry UI
    /// (a plain `try?` would mislabel network failures as "no record").
    private enum LookupOutcome: Sendable {
        case found(CatalogBook)
        case none
        case failure(String)
    }

    private func process(_ id: String) async {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              items[idx].status == .queued else { return }
        items[idx].status = .processing
        persist()
        let isbn = items[idx].isbn
        // Local copy: the @Sendable deadline closure can't touch the
        // MainActor-isolated `catalog` property directly.
        let catalog = self.catalog
        let result = await withDeadline(seconds: lookupDeadline) {
            do {
                if let book = try await catalog.lookup(isbn: isbn, preferred: .openlibrary) {
                    return LookupOutcome.found(book)
                }
                return LookupOutcome.none
            } catch {
                return LookupOutcome.failure(error.localizedDescription)
            }
        }
        switch (result.value, result.timedOut) {
        case (_, true):
            update(id: id, status: .failed, book: nil,
                   error: "The catalog took too long to answer. Retry when you have a better connection.")
        case (.some(.found(let book)), false):
            update(id: id, status: .ready, book: book, error: nil)
        case (.some(.failure(let message)), false):
            update(id: id, status: .failed, book: nil, error: message)
        default:
            update(id: id, status: .unavailable,
                   book: CatalogBook.manualStub(isbn: isbn), error: nil)
        }
    }

    private func update(id: String, status: ScanItemStatus, book: CatalogBook?, error: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
        items[idx].book = book
        items[idx].error = error
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func environmentSeed() -> [ScanQueueItem]? {
        // UI-test seam: seed pending/ready books from the launch environment so
        // the import flow is testable offline without a camera.
        var seeded: [ScanQueueItem] = []

        if let raw = ProcessInfo.processInfo.environment["UI_TEST_PENDING_SCANS"],
           let data = raw.data(using: .utf8),
           let books = try? JSONDecoder().decode([CatalogBook].self, from: data) {
            seeded += books.map {
                ScanQueueItem(id: $0.id, isbn: $0.isbn ?? "", status: .ready,
                              book: $0, enqueuedAt: Date(), error: nil)
            }
        }

        // Seed book-less scans (failed/never-resolved lookups) so callers can
        // exercise the non-importable review path deterministically — a real
        // unresolved scan would be mid-network-lookup and race with the test.
        if let raw = ProcessInfo.processInfo.environment["UI_TEST_PENDING_ISBNS"] {
            let isbns = raw
                .split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for isbn in isbns {
                if let normalized = Book.normalizedISBN(isbn) {
                    seeded.append(ScanQueueItem(id: "isbn-\(normalized)", isbn: normalized,
                                                status: .failed, book: nil,
                                                enqueuedAt: Date(),
                                                error: "Lookup unavailable in test environment."))
                }
            }
        }

        // Seed real queued ISBNs with auto-processing enabled (live catalog
        // lookup) so the background worker is exercised end-to-end without a
        // camera. Used by the live-lookup UI regression.
        if let raw = ProcessInfo.processInfo.environment["UI_TEST_LIVE_LOOKUP_ISBNS"] {
            let isbns = raw
                .split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for isbn in isbns {
                if let normalized = Book.normalizedISBN(isbn) {
                    seeded.append(ScanQueueItem(id: "isbn-\(normalized)", isbn: normalized,
                                                status: .queued, book: nil,
                                                enqueuedAt: Date(), error: nil))
                }
            }
        }

        return seeded.isEmpty ? nil : seeded
    }

    private static func load(from defaults: UserDefaults) -> [ScanQueueItem] {
        if let seeded = environmentSeed() {
            return seeded
        }

        if let data = defaults.data(forKey: key),
           var items = try? JSONDecoder().decode([ScanQueueItem].self, from: data) {
            // Crash recovery: lookups in flight at the moment of a crash restart
            // from a clean slate, and transient failures are worth another
            // attempt on a fresh launch.
            for idx in items.indices where items[idx].status == .processing || items[idx].status == .failed {
                items[idx].status = .queued
                items[idx].book = nil
            }
            return items
        }

        // Legacy migration: pre-queue builds stored raw CatalogBooks.
        if let data = defaults.data(forKey: Self.legacyKey),
           let books = try? JSONDecoder().decode([CatalogBook].self, from: data) {
            defaults.removeObject(forKey: Self.legacyKey)
            return books.map {
                ScanQueueItem(id: $0.id, isbn: $0.isbn ?? "", status: .ready,
                              book: $0, enqueuedAt: Date(), error: nil)
            }
        }

        return []
    }
}
