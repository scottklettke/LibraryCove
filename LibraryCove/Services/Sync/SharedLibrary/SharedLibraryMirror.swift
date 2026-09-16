import CoreData
import CryptoKit
import Foundation
import SwiftData

/// Local-side counterpart of `SharedLibraryEngine`: converts between the
/// SwiftData models and the `Shared*` DTOs, detects local edits/deletions via
/// a payload-hash index, and applies pulled changes to the mirror store.
///
/// The index (`shared-mirror-index.json`) maps record name → SHA256 of the
/// last-synced payload. A record is dirty when its current hash differs; a
/// record name present in the index but absent locally was deleted here.
/// This captures deletions without touching the app's `modelContext.delete`
/// call sites, which don't write tombstones.
final class SharedLibraryMirror {
    struct Index: Codable {
        var hashes: [String: String] = [:]
    }

    /// One locally-known record: its DTO payload plus the model object.
    struct Entry {
        let recordName: String
        let payload: Data
        let hash: String
        let book: Book?
        let note: Note?
        let list: ReadingList?
        let item: ReadingListItem?
    }

    enum PushChange: Equatable {
        case upsert(Entry)
        case delete(recordName: String)

        /// Entry isn't Equatable (holds live model objects); change identity
        /// is the record name plus case, which is all consumers compare.
        static func == (lhs: PushChange, rhs: PushChange) -> Bool {
            switch (lhs, rhs) {
            case (.delete(let a), .delete(let b)): return a == b
            case (.upsert(let a), .upsert(let b)): return a.recordName == b.recordName
            default: return false
            }
        }
    }

    // MARK: - Index persistence

    static var indexURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("shared-mirror-index.json")
    }
    func loadIndex() -> Index {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return Index() }
        return index
    }

    func saveIndex(_ index: Index) {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    // MARK: - Local scan

    /// Fetches every model row from the mirror store and snapshots it into
    /// entries. One scan serves both pull-side conflict checks and push-side
    /// dirty detection.
    func scan(context: ModelContext) -> [Entry] {
        var entries: [Entry] = []

        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for book in books {
            entries.append(entry(recordName: SharedLibraryRecord.recordName(type: .book, id: book.id),
                                 payload: Self.payloadData(Self.dto(from: book)),
                                 book: book, note: nil, list: nil, item: nil))
        }
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        for note in notes {
            entries.append(entry(recordName: SharedLibraryRecord.recordName(type: .note, id: note.id),
                                 payload: Self.payloadData(Self.dto(from: note)),
                                 book: nil, note: note, list: nil, item: nil))
        }
        let lists = (try? context.fetch(FetchDescriptor<ReadingList>())) ?? []
        for list in lists {
            entries.append(entry(recordName: SharedLibraryRecord.recordName(type: .readingList, id: list.id),
                                 payload: Self.payloadData(Self.dto(from: list)),
                                 book: nil, note: nil, list: list, item: nil))
        }
        let items = (try? context.fetch(FetchDescriptor<ReadingListItem>())) ?? []
        for item in items {
            entries.append(entry(recordName: SharedLibraryRecord.recordName(type: .readingListItem, id: item.id),
                                 payload: Self.payloadData(Self.dto(from: item)),
                                 book: nil, note: nil, list: nil, item: item))
        }
        return entries
    }

    private func entry(recordName: String, payload: Data, book: Book?, note: Note?,
                       list: ReadingList?, item: ReadingListItem?) -> Entry {
        Entry(recordName: recordName,
              payload: payload,
              hash: Self.sha256(payload),
              book: book, note: note, list: list, item: item)
    }

    /// Computes the push set against the index: changed/new records upsert,
    /// indexed-but-missing records delete.
    func pushChanges(entries: [Entry], index: Index) -> [PushChange] {
        var changes: [PushChange] = []
        var seen: Set<String> = []
        for entry in entries {
            seen.insert(entry.recordName)
            if index.hashes[entry.recordName] != entry.hash {
                changes.append(.upsert(entry))
            }
        }
        for name in index.hashes.keys where !seen.contains(name) {
            changes.append(.delete(recordName: name))
        }
        return changes
    }

    // MARK: - Applying pulled changes

    /// Applies pulled changes to the mirror store. `entriesByName` is the
    /// local scan, `index` is mutated in place. Returns the number of applied
    /// (non-skip) changes.
    ///
    /// Conflict policy: a locally-dirty record (index hash ≠ local hash) loses
    /// to the server only when the server copy is newer by `updatedAt`; ties
    /// go to the server. Winners keep/restore their dirty state so the next
    /// push re-uploads them (last-writer-wins per record).
    @discardableResult
    func apply(changes: [SharedRecordChange],
               assets: [String: Data],
               entriesByName: [String: Entry],
               index: inout Index,
               context: ModelContext) -> Int {
        var applied = 0

        // Type-phased so relationships resolve within one batch regardless of
        // arrival order: books first, then notes/lists, then items.
        let ordered = changes.sorted { rank($0) < rank($1) }
        func rank(_ change: SharedRecordChange) -> Int {
            switch change.kind {
            case .book: return 0
            case .note: return 1
            case .readingList: return 2
            case .readingListItem: return 3
            case .deleted(let name):
                return SharedLibraryRecord.RecordType(recordName: name)?.rank ?? 4
            }
        }

        for change in ordered {
            switch change.kind {
            case .book(let dto):
                if applyBook(dto, assetData: assets[change.recordName],
                             local: entriesByName[change.recordName],
                             index: &index, context: context) { applied += 1 }
            case .note(let dto):
                if applyNote(dto, local: entriesByName[change.recordName],
                             index: &index, context: context) { applied += 1 }
            case .readingList(let dto):
                if applyList(dto, local: entriesByName[change.recordName],
                             index: &index, context: context) { applied += 1 }
            case .readingListItem(let dto):
                if applyItem(dto, local: entriesByName[change.recordName],
                             index: &index, context: context) { applied += 1 }
            case .deleted(let recordName):
                if applyDelete(recordName: recordName, index: &index, context: context) { applied += 1 }
            }
        }

        if applied > 0 { try? context.save() }
        return applied
    }

    /// True when the incoming copy should replace the local record.
    private func serverShouldWin(recordName: String, incoming: Data,
                                 local: Entry?, index: Index,
                                 localUpdatedAt: Date, incomingUpdatedAt: Date) -> Bool {
        guard let local else { return true }                    // nothing local — take it
        guard let syncedHash = index.hashes[recordName] else { return true } // unknown to the cloud — take it
        let localDirty = local.hash != syncedHash
        if !localDirty { return true }                          // local is clean — take server
        // Both sides changed since last sync: last-writer-wins, ties to server.
        if localUpdatedAt > incomingUpdatedAt {
            // Local wins: adopt the synced state to the INCOMING payload hash?
            // No — keep the old index hash so the local edit stays dirty and
            // pushes after this sync.
            return false
        }
        return true
    }

    private func applyBook(_ dto: SharedBook, assetData: Data?,
                           local: Entry?, index: inout Index, context: ModelContext) -> Bool {
        let existing: Book? = local?.book ?? fetchByID(dto.id, context: context)
        guard serverShouldWin(recordName: SharedLibraryRecord.recordName(type: .book, id: dto.id),
                              incoming: Self.payloadData(dto), local: local, index: index,
                              localUpdatedAt: existing?.updatedAt ?? .distantPast,
                              incomingUpdatedAt: dto.updatedAt) else { return false }

        let book = existing ?? Book(id: dto.id, title: dto.title)
        book.title = dto.title
        book.authors = dto.authors
        book.isbn = dto.isbn
        book.publicationYear = dto.publicationYear
        book.tags = dto.tags
        book.kind = dto.kind
        book.shelves = dto.shelves
        book.publisher = dto.publisher
        book.pageCount = dto.pageCount
        book.bookDescription = dto.bookDescription
        book.descriptionSource = dto.descriptionSource
        book.olKey = dto.olKey
        book.series = dto.series
        book.genre = dto.genre
        book.language = dto.language
        book.physicalLocation = dto.physicalLocation
        book.status = dto.status
        book.acquiredDate = dto.acquiredDate
        book.purchasePrice = dto.purchasePrice
        book.rating = dto.rating
        book.loanedTo = dto.loanedTo
        book.loanedDate = dto.loanedDate
        book.ownerID = dto.ownerID
        book.sharedLibraryID = dto.sharedLibraryID
        book.isPersonal = dto.isPersonal
        book.createdAt = dto.createdAt
        book.updatedAt = dto.updatedAt
        applyCover(to: book, dtoCoverURL: dto.coverImageURL, fingerprint: dto.coverFingerprint,
                   assetData: assetData)
        if existing == nil { context.insert(book) }
        index.hashes[SharedLibraryRecord.recordName(type: .book, id: dto.id)] = Self.sha256(Self.payloadData(dto))
        return true
    }

    /// Cover precedence: asset bytes (materialized into the local cover file)
    /// beat the remote URL; remote URL replaces whatever was there. Local-only
    /// tokens from before sharing never travel — the receiver materializes
    /// from asset bytes or keeps the remote URL.
    private func applyCover(to book: Book, dtoCoverURL: String?, fingerprint: String?,
                            assetData: Data?) {
        if let assetData {
            CoverImageStore.save(assetData, forBookID: book.id)
            book.coverImageURL = CoverImageStore.zipEntryName(forBookID: book.id)
            return
        }
        // No asset: only replace the local cover if the fingerprint changed —
        // protects a locally-newer cover from being downgraded mid-conflict.
        if let fingerprint, fingerprint != Self.coverFingerprint(for: book) {
            CoverImageStore.delete(forBookID: book.id)
            book.coverImageURL = dtoCoverURL?.hasPrefix("http") == true ? dtoCoverURL : nil
        }
    }

    private func applyNote(_ dto: SharedNote, local: Entry?, index: inout Index, context: ModelContext) -> Bool {
        let existing: Note? = local?.note ?? fetchByID(dto.id, context: context)
        guard serverShouldWin(recordName: SharedLibraryRecord.recordName(type: .note, id: dto.id),
                              incoming: Self.payloadData(dto), local: local, index: index,
                              localUpdatedAt: existing?.updatedAt ?? .distantPast,
                              incomingUpdatedAt: dto.updatedAt) else { return false }

        let note = existing ?? Note(id: dto.id, book: nil, userID: dto.userID, content: dto.content)
        note.book = fetchBook(dto.bookID, context: context)
        note.userID = dto.userID
        note.title = dto.title
        note.content = dto.content
        note.noteType = dto.noteType
        note.visibility = dto.visibility
        note.sharedLibraryID = dto.sharedLibraryID
        note.pageReference = dto.pageReference
        note.mentions = dto.mentions
        note.createdAt = dto.createdAt
        note.updatedAt = dto.updatedAt
        if existing == nil { context.insert(note) }
        index.hashes[SharedLibraryRecord.recordName(type: .note, id: dto.id)] = Self.sha256(Self.payloadData(dto))
        return true
    }

    private func applyList(_ dto: SharedReadingList, local: Entry?, index: inout Index, context: ModelContext) -> Bool {
        let existing: ReadingList? = local?.list ?? fetchByID(dto.id, context: context)
        guard serverShouldWin(recordName: SharedLibraryRecord.recordName(type: .readingList, id: dto.id),
                              incoming: Self.payloadData(dto), local: local, index: index,
                              localUpdatedAt: existing?.updatedAt ?? .distantPast,
                              incomingUpdatedAt: dto.updatedAt) else { return false }

        let list = existing ?? ReadingList(id: dto.id, name: dto.name, ownerID: dto.ownerID)
        list.name = dto.name
        list.listDescription = dto.listDescription
        list.ownerID = dto.ownerID
        list.sharedLibraryID = dto.sharedLibraryID
        list.isPrivate = dto.isPrivate
        list.createdAt = dto.createdAt
        list.updatedAt = dto.updatedAt
        if existing == nil { context.insert(list) }
        index.hashes[SharedLibraryRecord.recordName(type: .readingList, id: dto.id)] = Self.sha256(Self.payloadData(dto))
        return true
    }

    private func applyItem(_ dto: SharedReadingListItem, local: Entry?, index: inout Index, context: ModelContext) -> Bool {
        let existing: ReadingListItem? = local?.item ?? fetchByID(dto.id, context: context)
        guard serverShouldWin(recordName: SharedLibraryRecord.recordName(type: .readingListItem, id: dto.id),
                              incoming: Self.payloadData(dto), local: local, index: index,
                              localUpdatedAt: existing?.createdAt ?? .distantPast,
                              incomingUpdatedAt: dto.createdAt) else { return false }

        let item = existing ?? ReadingListItem(id: dto.id)
        item.list = fetchList(dto.listID, context: context)
        item.book = fetchBook(dto.bookID, context: context)
        item.addedByID = dto.addedByID
        item.position = dto.position
        item.priority = dto.priority
        item.targetDate = dto.targetDate
        item.createdAt = dto.createdAt
        if existing == nil { context.insert(item) }
        index.hashes[SharedLibraryRecord.recordName(type: .readingListItem, id: dto.id)] = Self.sha256(Self.payloadData(dto))
        return true
    }

    private func applyDelete(recordName: String, index: inout Index, context: ModelContext) -> Bool {
        index.hashes.removeValue(forKey: recordName)
        guard let type = SharedLibraryRecord.RecordType(recordName: recordName),
              let id = SharedLibraryRecord.id(fromRecordName: recordName) else { return false }
        switch type {
        case .book:
            if let book: Book = fetchByID(id, context: context) { context.delete(book) }
        case .note:
            if let note: Note = fetchByID(id, context: context) { context.delete(note) }
        case .readingList:
            if let list: ReadingList = fetchByID(id, context: context) { context.delete(list) }
        case .readingListItem:
            if let item: ReadingListItem = fetchByID(id, context: context) { context.delete(item) }
        }
        return true
    }

    // MARK: - Push bookkeeping

    /// Records successfully-pushed entries into the index (failed ones stay
    /// dirty and retry next sync).
    func markSynced(entries: [Entry], failedRecordNames: Set<String>, index: inout Index) {
        for entry in entries where !failedRecordNames.contains(entry.recordName) {
            index.hashes[entry.recordName] = entry.hash
        }
    }

    // MARK: - DTO conversion

    static func dto(from book: Book) -> SharedBook {
        var dto = SharedBook(id: book.id)
        dto.title = book.title
        dto.authors = book.authors
        dto.isbn = book.isbn
        dto.publicationYear = book.publicationYear
        dto.tags = book.tags
        dto.kind = book.kind
        dto.shelves = book.shelves
        // Only remote references travel; bytes go via payload/asset (codec).
        dto.coverImageURL = book.coverImageURL?.hasPrefix("http") == true ? book.coverImageURL : nil
        dto.coverFingerprint = coverFingerprint(for: book)
        dto.publisher = book.publisher
        dto.pageCount = book.pageCount
        dto.bookDescription = book.bookDescription
        dto.descriptionSource = book.descriptionSource
        dto.olKey = book.olKey
        dto.series = book.series
        dto.genre = book.genre
        dto.language = book.language
        dto.physicalLocation = book.physicalLocation
        dto.status = book.status
        dto.acquiredDate = book.acquiredDate
        dto.purchasePrice = book.purchasePrice
        dto.rating = book.rating
        dto.loanedTo = book.loanedTo
        dto.loanedDate = book.loanedDate
        dto.ownerID = book.ownerID
        dto.sharedLibraryID = book.sharedLibraryID
        dto.isPersonal = book.isPersonal
        dto.createdAt = book.createdAt
        dto.updatedAt = book.updatedAt
        return dto
    }

    static func dto(from note: Note) -> SharedNote {
        var dto = SharedNote(id: note.id, bookID: note.book?.id ?? "", userID: note.userID)
        dto.title = note.title
        dto.content = note.content
        dto.noteType = note.noteType
        dto.visibility = note.visibility
        dto.sharedLibraryID = note.sharedLibraryID
        dto.pageReference = note.pageReference
        dto.mentions = note.mentions
        dto.createdAt = note.createdAt
        dto.updatedAt = note.updatedAt
        return dto
    }

    static func dto(from list: ReadingList) -> SharedReadingList {
        var dto = SharedReadingList(id: list.id)
        dto.name = list.name
        dto.listDescription = list.listDescription
        dto.ownerID = list.ownerID
        dto.sharedLibraryID = list.sharedLibraryID
        dto.isPrivate = list.isPrivate
        dto.createdAt = list.createdAt
        dto.updatedAt = list.updatedAt
        return dto
    }

    static func dto(from item: ReadingListItem) -> SharedReadingListItem {
        var dto = SharedReadingListItem(id: item.id,
                                        listID: item.list?.id ?? "",
                                        bookID: item.book?.id ?? "")
        dto.addedByID = item.addedByID
        dto.position = item.position
        dto.priority = item.priority
        dto.targetDate = item.targetDate
        dto.createdAt = item.createdAt
        return dto
    }

    /// Cover bytes for syncing: local file token or data: URL both resolve.
    static func bestCoverData(for book: Book) -> Data? {
        CoverImageStore.localData(forCover: book.coverImageURL)
    }

    /// Stable fingerprint of a book's cover bytes so cover-only edits dirty
    /// the payload (the URL field itself stays remote-or-nil).
    static func coverFingerprint(for book: Book) -> String? {
        guard let data = bestCoverData(for: book), !data.isEmpty else { return nil }
        return sha256(data)
    }

    // MARK: - Payload helpers

    static func payloadData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Fetch helpers

    private func fetchBook(_ id: String, context: ModelContext) -> Book? {
        fetchByID(id, context: context)
    }

    private func fetchList(_ id: String, context: ModelContext) -> ReadingList? {
        fetchByID(id, context: context)
    }

    private func fetchByID<T: PersistentModel & Identifiable>(_ id: String, context: ModelContext) -> T? where T.ID == String {
        var descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

private extension SharedLibraryRecord.RecordType {
    /// Apply order for pulled changes (books before their children).
    var rank: Int {
        switch self {
        case .book: return 0
        case .note: return 1
        case .readingList: return 2
        case .readingListItem: return 3
        }
    }
}
