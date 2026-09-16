import Foundation
import SwiftData

/// Errors reported by the export/import/delete service.
enum LibraryDataError: LocalizedError {
    case exportFailed
    case invalidArchive
    case unsupportedVersion
    case importFailed

    var errorDescription: String? {
        switch self {
        case .exportFailed:
            return "Could not build the export file."
        case .invalidArchive:
            return "That file is not a valid LibraryCove library export."
        case .unsupportedVersion:
            return "That file uses an unsupported export format version."
        case .importFailed:
            return "The library could not be imported from that file."
        }
    }
}

/// Human-readable counts describing an archive, used for previews and results.
struct ImportSummary {
    var users = 0
    var books = 0
    var notes = 0
    var readingLists = 0
    var readingListItems = 0
    var connections = 0
    /// Records removed when an import replaces the existing library.
    var deletedBeforeImport = 0

    init(_ envelope: ExportEnvelope, deletedBeforeImport: Int = 0) {
        users = envelope.users.count
        books = envelope.books.count
        notes = envelope.notes.count
        readingLists = envelope.readingLists.count
        readingListItems = envelope.readingListItems.count
        connections = envelope.connections.count
        self.deletedBeforeImport = deletedBeforeImport
    }

    var total: Int {
        users + books + notes + readingLists + readingListItems + connections
    }

    var formatted: String {
        "\(books) book\(books == 1 ? "" : "s"), \(notes) note\(notes == 1 ? "" : "s"), "
        + "\(readingLists) reading list\(readingLists == 1 ? "" : "s"), "
        + "\(readingListItems) list item\(readingListItems == 1 ? "" : "s"), "
        + "\(connections) connection\(connections == 1 ? "" : "s"), "
        + "\(users) member\(users == 1 ? "" : "s")"
    }
}

/// Export/import/delete for the entire library.
///
/// The archive is a standard ZIP containing:
///   - `library.json`  — the full library in readable JSON (see `EXPORT-FORMAT.md`)
///   - `covers/*.jpg`  — one JPEG file per book cover
///   - `README-FORMAT.md` — the same step-by-step format guide, shipped with the file
@MainActor
enum LibraryDataService {
    static let formatMarker = "librarycove-library"
    static let version = 1
    static let archiveFileName = "library.json"
    static let readmeFileName = "README-FORMAT.md"

    /// File name for a shareable export: `LibraryCove-<Kind>-<Library>-<yyyy-MM-dd>.<ext>`
    /// where Kind is "Library" (zip) or "Catalog" (PDF). Characters illegal
    /// in file names (`/:`) are replaced with `-`; an unnamed library falls
    /// back to the member's default share title so the file is still identifiable.
    static func exportFileName(kind: String, libraryName: String, memberName: String, ext: String, date: Date = Date()) -> String {
        let rawName = libraryName.isEmpty ? SharedLibrarySettings.defaultShareTitle(for: memberName) : libraryName
        let sanitized = rawName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "LibraryCove-\(kind)-\(sanitized)-\(formatter.string(from: date)).\(ext)"
    }

    /// The active member's display name — the fallback half of export file
    /// names when the library itself is unnamed.
    static func activeMemberName(_ context: ModelContext) -> String {
        (try? context.fetch(FetchDescriptor<User>()))?.first(where: \.isActive)?.displayName ?? ""
    }

    // MARK: - Export

    /// Fetches the bytes of a remote cover image. Returns `nil` on failure so
    /// the export can keep the original remote URL as a fallback.
    static func fetchRemoteCover(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              !data.isEmpty else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return data
    }

    /// Serialises the whole library into a zipped archive (`library.json` +
    /// guide + `covers/*.jpg`). Covers are stored on the filesystem AND bundled
    /// as separate JPEG files inside the zip (a `data:`-encoded cover is decoded,
    /// a remote URL is downloaded; one fetch per distinct URL, concurrently).
    /// Each materialised cover is written into `CoverImageStore` and the zip as
    /// `covers/<bookID>.jpg`, and the book's `coverImageFile` points at the zip
    /// entry while `coverImageURL` is cleared. Covers that can't be materialised
    /// keep their original URL rather than failing the export. `fetchRemoteCover`
    /// is injectable for testing.
    static func export(context: ModelContext,
                       fetchRemoteCover: @escaping (URL) async -> Data? = Self.fetchRemoteCover) async -> Data? {
        // Exports the ACTIVE library's content (multi-library).
        let libraryID = LibraryScope.shared.activeID(context: context)
        let users = (try? context.fetch(FetchDescriptor<User>())) ?? []
        let books = (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []
        let notes = (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []
        let lists = (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []
        let items = (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []
        let connections = (try? context.fetch(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []

        // Fetch each distinct remote cover once.
        let remoteCovers = Set(books.compactMap(\.coverImageURL)
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") })
        var fetchedRemotes: [String: Data] = [:]
        if !remoteCovers.isEmpty {
            await withTaskGroup(of: (String, Data?).self) { group in
                for urlString in remoteCovers {
                    group.addTask {
                        guard let url = URL(string: urlString) else { return (urlString, nil) }
                        return (urlString, await fetchRemoteCover(url))
                    }
                }
                for await (urlString, data) in group where data != nil {
                    fetchedRemotes[urlString] = data
                }
            }
        }

        func coverBytes(for model: Book) -> Data? {
            guard let cover = model.coverImageURL else { return nil }
            if cover.hasPrefix("http://") || cover.hasPrefix("https://") {
                return fetchedRemotes[cover]
            }
            return CoverImageStore.localData(forCover: cover)
        }

        var coverEntries: [(name: String, data: Data)] = []
        let bookDTOs = books.map { model in
            var dto = BookDTO(model: model)
            guard let bytes = coverBytes(for: model) else { return dto }
            let entryName = CoverImageStore.zipEntryName(forBookID: model.id)
            if CoverImageStore.save(bytes, forBookID: model.id) {  // local, filesystem copy
                coverEntries.append((entryName, bytes))
                dto.coverImageFile = entryName
                dto.coverImageURL = nil
            }
            return dto
        }

        let envelope = ExportEnvelope(
            format: formatMarker,
            version: version,
            exportedAt: Date(),
            users: users.map(UserDTO.init(model:)),
            books: bookDTOs,
            notes: notes.map(NoteDTO.init(model:)),
            readingLists: lists.map(ReadingListDTO.init(model:)),
            readingListItems: items.map(ReadingListItemDTO.init(model:)),
            connections: connections.map(ConnectionDTO.init(model:))
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try? encoder.encode(envelope) else { return nil }

        var entries: [(name: String, data: Data)] = [
            (archiveFileName, json),
            (readmeFileName, Data(formatGuide.utf8)),
        ]
        entries.append(contentsOf: coverEntries)
        return ZipArchive.create(entries: entries)
    }

    // MARK: - Preview / import

    /// Reads an archive and returns what it holds, without touching the library.
    static func previewArchive(data: Data) throws -> ImportSummary {
        ImportSummary(try loadArchive(data).envelope)
    }

    /// Replaces the library with the contents of an archive. Parses and
    /// validates the file before deleting anything. Returns what was imported.
    @discardableResult
    static func importArchive(data: Data, context: ModelContext) throws -> ImportSummary {
        var loaded = try loadArchive(data)
        // Replace-import targets the ACTIVE library only: its content is
        // deleted, the archive becomes the active library's content. Other
        // libraries are untouched.
        let libraryID = LibraryScope.shared.activeID(context: context)
        let deleted = deleteLibraryContent(context: context, libraryID: libraryID)
        restoreCovers(from: &loaded.envelope, files: loaded.files)
        insert(loaded.envelope, into: context)
        try context.save()
        return ImportSummary(loaded.envelope, deletedBeforeImport: deleted)
    }

    /// Deletes one library's content rows (books, notes, lists, items,
    /// connections) — NOT its Library row, NOT other libraries, NOT members.
    @discardableResult
    static func deleteLibraryContent(context: ModelContext, libraryID: String) -> Int {
        let bookCount = (try? context.fetchCount(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? 0
        let noteCount = (try? context.fetchCount(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? 0
        let listCount = (try? context.fetchCount(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? 0
        let itemCount = (try? context.fetchCount(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? 0
        let connectionCount = (try? context.fetchCount(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? 0
        let total = bookCount + noteCount + listCount + itemCount + connectionCount

        for row in (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? [] { context.delete(row) }
        try? context.save()
        return total
    }

    /// Deletes every record so the user starts fresh — including the member
    /// identity, so the app returns to the login screen. Returns how many
    /// were removed.
    @discardableResult
    static func deleteAll(context: ModelContext) -> Int {
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        }
        let total = count(User.self)
            + count(Book.self)
            + count(Note.self)
            + count(ReadingList.self)
            + count(ReadingListItem.self)
            + count(Connection.self)

        try? context.delete(model: User.self)
        try? context.delete(model: Book.self)
        try? context.delete(model: Note.self)
        try? context.delete(model: ReadingList.self)
        try? context.delete(model: ReadingListItem.self)
        try? context.delete(model: Connection.self)
        try? context.save()

        // Delete-everything also clears the library registry; LibraryScope
        // recreates a default on next access.
        LibraryScope.shared.deleteAllLibraries()

        // Covers live on the filesystem, so clearing the database must purge
        // them too.
        CoverImageStore.removeAll()

        return total
    }

    /// Deletes the LIBRARY CONTENT only — books, notes, reading lists, and
    /// connections — keeping the member identity (the user stays logged in)
    /// and landing on the "Your library is empty" page. Returns how many
    /// were removed.
    @discardableResult
    static func deleteLibraryContent(context: ModelContext) -> Int {
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        }
        let total = count(Book.self)
            + count(Note.self)
            + count(ReadingList.self)
            + count(ReadingListItem.self)
            + count(Connection.self)

        try? context.delete(model: Book.self)
        try? context.delete(model: Note.self)
        try? context.delete(model: ReadingList.self)
        try? context.delete(model: ReadingListItem.self)
        try? context.delete(model: Connection.self)
        try? context.save()

        // Library content is gone; its covers have no owner anymore.
        CoverImageStore.removeAll()

        return total
    }

    /// Deletes the ACTIVE library's content (multi-library aware). Used by
    /// Delete Library, which must not touch other libraries.
    @discardableResult
    static func deleteActiveLibraryContent(context: ModelContext) -> Int {
        deleteLibraryContent(context: context,
                             libraryID: LibraryScope.shared.activeID(context: context))
    }

    // MARK: - Decoding

    /// Unzips and validates an archive, returning its envelope plus the raw
    /// file entries (so bundled cover JPEGs can be restored).
    static func loadArchive(_ data: Data) throws -> (envelope: ExportEnvelope, files: [String: Data]) {
        let files: [String: Data]
        do {
            files = try ZipArchive.unzip(data)
        } catch {
            throw LibraryDataError.invalidArchive
        }
        guard let json = files[archiveFileName] else {
            throw LibraryDataError.invalidArchive
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: ExportEnvelope
        do {
            envelope = try decoder.decode(ExportEnvelope.self, from: json)
        } catch {
            throw LibraryDataError.invalidArchive
        }
        guard envelope.format == formatMarker || envelope.format == "booknexus-library" else {
            throw LibraryDataError.invalidArchive
        }
        guard envelope.version == version else { throw LibraryDataError.unsupportedVersion }
        return (envelope, files)
    }

    // MARK: - Merge import

    /// The books an archive would add with a merge. Non-mutating, so import
    /// can show the list before doing anything (matched by ISBN, else title +
    /// first author). Returns DTOs in archive order.
    static func mergeCandidates(data: Data, context: ModelContext) throws -> [BookDTO] {
        let loaded = try loadArchive(data)
        let keys = knownBookKeys(context: context)
        return loaded.envelope.books.filter {
            !bookAlreadyKnown($0, isbns: keys.isbns, titleKeys: keys.titleKeys)
        }
    }

    /// Adds only the books from an archive that aren't already known locally
    /// (matched by ISBN, else title + first author). Existing data is never
    /// touched. Returns what was actually added.
    @discardableResult
    static func mergeArchive(data: Data, context: ModelContext) throws -> ImportSummary {
        var loaded = try loadArchive(data)
        let keys = knownBookKeys(context: context)
        loaded.envelope.books = loaded.envelope.books.filter {
            !bookAlreadyKnown($0, isbns: keys.isbns, titleKeys: keys.titleKeys)
        }
        // Bundled covers for the newly-added books are restored too (skipped
        // books already exist locally, so their covers are left alone).
        restoreCovers(from: &loaded.envelope, files: loaded.files)
        insert(loaded.envelope, into: context)
        try context.save()
        return ImportSummary(loaded.envelope)
    }

    /// Migrates the context to EXACTLY the archive's content: deletes every
    /// Book row whose id is absent from the archive, copies the rest 1:1
    /// (same-id rows keep their local row; new ids insert). NO ISBN/title
    /// dedupe — duplicate copies with distinct UUIDs survive.
    ///
    /// This is the provider-switch semantic. Union-style copying (plain
    /// copyArchive) made the target store ACCUMULATE: rows left over from an
    /// earlier era (e.g. CloudKit re-delivered a pre-fresh-start library)
    /// rode along through every switch round trip, doubling the library.
    /// The snapshot is authoritative — the target should match it exactly.
    ///
    /// Deletes are targeted (specific ids), not deleteAll: CloudKit
    /// propagates per-record deletions cleanly, and only rows the archive
    /// genuinely replaced are removed.
    @discardableResult
    static func migrateArchive(data: Data, context: ModelContext) throws -> ImportSummary {
        var loaded = try loadArchive(data)
        let libraryID = LibraryScope.shared.activeID(context: context)
        let archiveBookIDs = Set(loaded.envelope.books.map(\.id))
        let stale = ((try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? [])
            .filter { !archiveBookIDs.contains($0.id) }
        for row in stale {
            context.delete(row)
        }
        let existingBookIDs = Set(((try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []).map(\.id))
        loaded.envelope.books = loaded.envelope.books.filter { !existingBookIDs.contains($0.id) }
        restoreCovers(from: &loaded.envelope, files: loaded.files)
        insert(loaded.envelope, into: context)
        try context.save()
        return ImportSummary(loaded.envelope)
    }

    /// Copies an archive into the context 1:1 — NO dedupe by ISBN or
    /// title+authors. Duplicate books in the archive (same title, distinct
    /// UUIDs) stay duplicate books. Used by the provider-switch engine and
    /// the shared-library hand-off, where the snapshot IS the user's
    /// authoritative library and collapsing same-title copies would
    /// silently lose data.
    ///
    /// Rows whose BOOK ID already exists in the target are skipped — those
    /// are the same book, not a distinct copy, so skipping makes a
    /// re-poured snapshot idempotent (a crash mid-pour before the snapshot
    /// is cleared would otherwise double-insert every row on retry).
    /// Known tradeoff: legacy stores may hold distinct copies that SHARE
    /// one id (pre-0a55c79 merge bug); for those the id-skip drops the
    /// target's second row instead of merging content. Accepted — distinct
    /// copies created since carry distinct UUIDs. If a user ever reports a
    /// copy missing with MATCHING ids, this is where it went.
    @discardableResult
    static func copyArchive(data: Data, context: ModelContext) throws -> ImportSummary {
        var loaded = try loadArchive(data)
        let activeLibraryID = LibraryScope.shared.activeID(context: context)
        let existingBookIDs = Set(((try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == activeLibraryID }
        ))) ?? []).map(\.id))
        if !existingBookIDs.isEmpty {
            loaded.envelope.books = loaded.envelope.books.filter { !existingBookIDs.contains($0.id) }
        }
        restoreCovers(from: &loaded.envelope, files: loaded.files)
        insert(loaded.envelope, into: context)
        try context.save()
        return ImportSummary(loaded.envelope)
    }

    private static func knownBookKeys(context: ModelContext) -> (isbns: Set<String>, titleKeys: Set<String>) {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        var isbns = Set<String>()
        var titleKeys = Set<String>()
        for book in books {
            if let isbn = Book.normalizedISBN(book.isbn) {
                isbns.insert(isbn)
            } else {
                titleKeys.insert(bookTitleKey(book.title, authors: book.authors))
            }
        }
        return (isbns, titleKeys)
    }

    private static func bookTitleKey(_ title: String, authors: [String]) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let a = authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }.sorted().joined(separator: "|")
        return "\(t)|\(a)"
    }

    /// A book counts as already known when its ISBN matches, or (no ISBN) its
    /// title + authors match an existing book.
    private static func bookAlreadyKnown(_ dto: BookDTO, isbns: Set<String>, titleKeys: Set<String>) -> Bool {
        if let isbn = Book.normalizedISBN(dto.isbn) { return isbns.contains(isbn) }
        return titleKeys.contains(bookTitleKey(dto.title, authors: dto.authors))
    }

    // MARK: - Cover sync migration

    /// One-time migration for the filesystem-cover era: books whose cover
    /// exists only as a local file (`covers/...` token or stale absolute path)
    /// get the bytes embedded as a `data:` URL so CloudKit syncs them to other
    /// devices. Idempotent — data/http covers are left alone; runs each launch.
    @MainActor
    static func materializeLocalCovers(context: ModelContext) {
        guard let books = try? context.fetch(FetchDescriptor<Book>()) else { return }
        var changed = false
        for book in books {
            guard let cover = book.coverImageURL else { continue }
            if cover.hasPrefix("data:")
                || cover.hasPrefix("http://")
                || cover.hasPrefix("https://") {
                continue
            }
            guard let bytes = CoverImageStore.localData(forCover: cover) else { continue }
            book.coverImageURL = CoverImageStore.dataURL(from: bytes)
            changed = true
        }
        if changed { try? context.save() }
    }

    // MARK: - Cover restoration

    /// Writes the bundled `covers/*.jpg` files to the filesystem store and
    /// points each book's `coverImageURL` at its local file URL so restored
    /// covers render offline. Books without a bundled cover keep whatever
    /// reference the file carried.
    private static func restoreCovers(from envelope: inout ExportEnvelope, files: [String: Data]) {
        for i in envelope.books.indices {
            guard let entryName = envelope.books[i].coverImageFile,
                  let bytes = files[entryName] else { continue }
            guard CoverImageStore.save(bytes, forBookID: envelope.books[i].id) else { continue }
            // Store the cover as an embedded data URL: that's the form that
            // syncs to other devices via CloudKit (CoverImageStore only backs
            // export bundling / offline file access).
            envelope.books[i].coverImageURL = CoverImageStore.dataURL(from: bytes)
        }
    }

    // MARK: - Insertion (relationship rewiring by id)

    private static func insert(_ envelope: ExportEnvelope, into context: ModelContext) {
        // User rows dedupe by id: merge imports can run repeatedly against
        // the same library, and duplicate ids would trip the
        // uniqueKeysWithValues dictionaries built from users elsewhere
        // (search, PDF export) — a fatal crash. First row wins.
        let existingUsers = (try? context.fetch(FetchDescriptor<User>())) ?? []
        var knownUserIDs = Set(existingUsers.map(\.id))
        var users: [String: User] = [:]
        for dto in envelope.users where !knownUserIDs.contains(dto.id) {
            let user = User(id: dto.id,
                            email: dto.email,
                            displayName: dto.displayName,
                            avatarURL: dto.avatarURL,
                            timezone: dto.timezone,
                            language: dto.language,
                            isActive: dto.isActive,
                            createdAt: dto.createdAt,
                            lastLoginAt: dto.lastLoginAt)
            context.insert(user)
            users[dto.id] = user
            knownUserIDs.insert(dto.id)
        }
        // Books may reference users that already exist locally (deduped away
        // above) — resolve those to the existing rows so relationships wire.
        for existing in existingUsers where users[existing.id] == nil { users[existing.id] = existing }

        var books: [String: Book] = [:]
        for dto in envelope.books {
            let book = Book(id: dto.id,
                            title: dto.title,
                            authors: dto.authors,
                            isbn: dto.isbn,
                            publicationYear: dto.publicationYear,
                            tags: dto.tags,
                            kind: dto.kind ?? "",
                            coverImageURL: dto.coverImageURL,
                            publisher: dto.publisher,
                            pageCount: dto.pageCount,
                            bookDescription: dto.bookDescription,
                            descriptionSource: dto.descriptionSource,
                            olKey: dto.olKey,
                            language: dto.language,
                            genre: dto.genre,
                            series: dto.series,
                            physicalLocation: dto.physicalLocation,
                            status: dto.status,
                            acquiredDate: dto.acquiredDate,
                            purchasePrice: dto.purchasePrice,
                            rating: dto.rating,
                            loanedTo: dto.loanedTo,
                            loanedDate: dto.loanedDate,
                            ownerID: dto.ownerID,
                            sharedLibraryID: dto.sharedLibraryID,
                            isPersonal: dto.isPersonal,
                            createdAt: dto.createdAt,
                            updatedAt: dto.updatedAt,
                            syncState: dto.syncState,
                            syncUpdatedAt: dto.syncUpdatedAt,
                            syncDeviceID: dto.syncDeviceID,
                            shelves: dto.shelves ?? [])
            context.insert(book)
            book.libraryID = LibraryScope.shared.activeID(context: context)
            books[dto.id] = book
        }

        var lists: [String: ReadingList] = [:]
        for dto in envelope.readingLists {
            let list = ReadingList(id: dto.id,
                                   name: dto.name,
                                   listDescription: dto.listDescription,
                                   ownerID: dto.ownerID,
                                   sharedLibraryID: dto.sharedLibraryID,
                                   isPrivate: dto.isPrivate,
                                   createdAt: dto.createdAt,
                                   updatedAt: dto.updatedAt,
                                   syncState: dto.syncState,
                                   syncUpdatedAt: dto.syncUpdatedAt,
                                   syncDeviceID: dto.syncDeviceID)
            context.insert(list)
            list.libraryID = LibraryScope.shared.activeID(context: context)
            lists[dto.id] = list
        }

        for dto in envelope.notes {
            let note = Note(id: dto.id,
                            book: nil,
                            userID: dto.userID,
                            title: dto.title,
                            content: dto.content,
                            noteType: dto.noteType,
                            visibility: dto.visibility,
                            sharedLibraryID: dto.sharedLibraryID,
                            pageReference: dto.pageReference,
                            mentions: dto.mentions,
                            createdAt: dto.createdAt,
                            updatedAt: dto.updatedAt,
                            syncState: dto.syncState,
                            syncUpdatedAt: dto.syncUpdatedAt,
                            syncDeviceID: dto.syncDeviceID)
            note.book = dto.bookID.flatMap { books[$0] }
            note.libraryID = LibraryScope.shared.activeID(context: context)
            context.insert(note)
        }

        for dto in envelope.readingListItems {
            let item = ReadingListItem(id: dto.id,
                                       list: nil,
                                       book: nil,
                                       addedByID: dto.addedByID,
                                       position: dto.position,
                                       priority: dto.priority,
                                       targetDate: dto.targetDate,
                                       createdAt: dto.createdAt,
                                       syncState: dto.syncState,
                                       syncUpdatedAt: dto.syncUpdatedAt,
                                       syncDeviceID: dto.syncDeviceID)
            item.list = dto.listID.flatMap { lists[$0] }
            item.book = dto.bookID.flatMap { books[$0] }
            item.libraryID = LibraryScope.shared.activeID(context: context)
            context.insert(item)
        }

        for dto in envelope.connections {
            let connection = Connection(id: dto.id,
                                        book1: nil,
                                        book2: nil,
                                        connectionType: dto.connectionType,
                                        connectionDescription: dto.connectionDescription,
                                        createdByID: dto.createdByID,
                                        sharedLibraryID: dto.sharedLibraryID,
                                        createdAt: dto.createdAt,
                                        syncState: dto.syncState,
                                        syncUpdatedAt: dto.syncUpdatedAt,
                                        syncDeviceID: dto.syncDeviceID)
            connection.book1 = dto.book1ID.flatMap { books[$0] }
            connection.book2 = dto.book2ID.flatMap { books[$0] }
            connection.libraryID = LibraryScope.shared.activeID(context: context)
            context.insert(connection)
        }
    }
}
