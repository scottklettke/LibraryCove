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
            return "That file is not a valid BookNexus library export."
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
    static let formatMarker = "booknexus-library"
    static let version = 1
    static let archiveFileName = "library.json"
    static let readmeFileName = "README-FORMAT.md"

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
        let users = (try? context.fetch(FetchDescriptor<User>())) ?? []
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let lists = (try? context.fetch(FetchDescriptor<ReadingList>())) ?? []
        let items = (try? context.fetch(FetchDescriptor<ReadingListItem>())) ?? []
        let connections = (try? context.fetch(FetchDescriptor<Connection>())) ?? []

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
        let deleted = deleteAll(context: context)
        restoreCovers(from: &loaded.envelope, files: loaded.files)
        insert(loaded.envelope, into: context)
        try context.save()
        return ImportSummary(loaded.envelope, deletedBeforeImport: deleted)
    }

    /// Deletes every record so the user starts fresh. Returns how many were
    /// removed.
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

        // Covers live on the filesystem, so clearing the database must purge
        // them too.
        CoverImageStore.removeAll()

        return total
    }

    // MARK: - Decoding

    /// Unzips and validates an archive, returning its envelope plus the raw
    /// file entries (so bundled cover JPEGs can be restored).
    private static func loadArchive(_ data: Data) throws -> (envelope: ExportEnvelope, files: [String: Data]) {
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
        guard envelope.format == formatMarker else { throw LibraryDataError.invalidArchive }
        guard envelope.version == version else { throw LibraryDataError.unsupportedVersion }
        return (envelope, files)
    }

    // MARK: - Merge import

    /// Adds only the books from an archive that aren't already known locally
    /// (matched by ISBN, else title + first author). Existing data is never
    /// touched. Returns what was actually added.
    @discardableResult
    static func mergeArchive(data: Data, context: ModelContext) throws -> ImportSummary {
        var loaded = try loadArchive(data)
        let (isbns, titleKeys) = knownBookKeys(context: context)
        loaded.envelope.books = loaded.envelope.books
            .filter { !bookAlreadyKnown($0, isbns: isbns, titleKeys: titleKeys) }
        // Bundled covers for the newly-added books are restored too (skipped
        // books already exist locally, so their covers are left alone).
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
            if let isbn = book.isbn, !isbn.isEmpty {
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
        if let isbn = dto.isbn, !isbn.isEmpty { return isbns.contains(isbn) }
        return titleKeys.contains(bookTitleKey(dto.title, authors: dto.authors))
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
            envelope.books[i].coverImageURL = CoverImageStore.fileURL(forBookID: envelope.books[i].id).absoluteString
        }
    }

    // MARK: - Insertion (relationship rewiring by id)

    private static func insert(_ envelope: ExportEnvelope, into context: ModelContext) {
        var users: [String: User] = [:]
        for dto in envelope.users {
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
        }

        var books: [String: Book] = [:]
        for dto in envelope.books {
            let book = Book(id: dto.id,
                            title: dto.title,
                            authors: dto.authors,
                            isbn: dto.isbn,
                            publicationYear: dto.publicationYear,
                            genres: dto.genres,
                            coverImageURL: dto.coverImageURL,
                            publisher: dto.publisher,
                            pageCount: dto.pageCount,
                            bookDescription: dto.bookDescription,
                            descriptionSource: dto.descriptionSource,
                            language: dto.language,
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
                            syncDeviceID: dto.syncDeviceID)
            context.insert(book)
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
            context.insert(connection)
        }
    }
}
