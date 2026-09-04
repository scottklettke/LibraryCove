import Foundation
import SwiftData

/// Serializable snapshots of each model type. JSON keys equal the model's
/// property names so the file is human-reviewable, and relationship properties
/// are exported as the referenced object's `id` string (or `null`).
///
/// A full reference lives in `EXPORT-FORMAT.md`.
struct ExportEnvelope: Codable {
    var format: String
    var version: Int
    var exportedAt: Date
    var users: [UserDTO]
    var books: [BookDTO]
    var notes: [NoteDTO]
    var readingLists: [ReadingListDTO]
    var readingListItems: [ReadingListItemDTO]
    var connections: [ConnectionDTO]
}

struct UserDTO: Codable {
    var id: String
    var email: String
    var displayName: String
    var avatarURL: String?
    var timezone: String
    var language: String
    var isActive: Bool
    var createdAt: Date
    var lastLoginAt: Date?

    init(model: User) {
        id = model.id
        email = model.email
        displayName = model.displayName
        avatarURL = model.avatarURL
        timezone = model.timezone
        language = model.language
        isActive = model.isActive
        createdAt = model.createdAt
        lastLoginAt = model.lastLoginAt
    }
}

struct BookDTO: Codable {
    var id: String
    var title: String
    var authors: [String]
    var isbn: String?
    var publicationYear: Int?
    var tags: [String]
    /// Fiction / non-fiction classification (`nil` when unset). New field; old
    /// archives won't have it.
    var kind: String?
    /// Manual shelf assignments (`nil` when the book has none).
    var shelves: [String]?
    var coverImageURL: String?
    /// Relative `covers/<bookID>.jpg` zip entry carrying the cover's JPEG
    /// bytes, set only on export. Presence tells import to restore from a file.
    var coverImageFile: String?
    var publisher: String?
    var pageCount: Int?
    var bookDescription: String?
    var descriptionSource: String?
    var language: String?
    var physicalLocation: String?
    var status: String
    var acquiredDate: Date?
    var purchasePrice: Double?
    var rating: Int?
    var loanedTo: String?
    var loanedDate: Date?
    var ownerID: String?
    var sharedLibraryID: String?
    var isPersonal: Bool
    var createdAt: Date
    var updatedAt: Date
    var syncState: String
    var syncUpdatedAt: Date
    var syncDeviceID: String

    init(model: Book) {
        id = model.id
        title = model.title
        authors = model.authors
        isbn = model.isbn
        publicationYear = model.publicationYear
        tags = model.tags
        kind = model.kind.isEmpty ? nil : model.kind
        shelves = model.shelves.isEmpty ? nil : model.shelves
        coverImageURL = model.coverImageURL
        coverImageFile = nil
        publisher = model.publisher
        pageCount = model.pageCount
        bookDescription = model.bookDescription
        descriptionSource = model.descriptionSource
        language = model.language
        physicalLocation = model.physicalLocation
        status = model.status
        acquiredDate = model.acquiredDate
        purchasePrice = model.purchasePrice
        rating = model.rating
        loanedTo = model.loanedTo
        loanedDate = model.loanedDate
        ownerID = model.ownerID
        sharedLibraryID = model.sharedLibraryID
        isPersonal = model.isPersonal
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        syncState = model.syncState
        syncUpdatedAt = model.syncUpdatedAt
        syncDeviceID = model.syncDeviceID
    }

    // Custom Codable: the tag field was renamed `genres` → `tags`. Exports emit
    // only the canonical `tags` key; imports accept either `tags` or the legacy
    // `genres` key so older archives still restore.
    private enum CodingKeys: String, CodingKey {
        case id, title, authors, isbn, publicationYear, tags, kind, coverImageURL
        case coverImageFile, publisher, pageCount, bookDescription, descriptionSource
        case language, physicalLocation, status, acquiredDate, purchasePrice, rating
        case loanedTo, loanedDate, ownerID, sharedLibraryID, isPersonal, createdAt
        case updatedAt, syncState, syncUpdatedAt, syncDeviceID, shelves
        case legacyTags = "genres"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        authors = try c.decode([String].self, forKey: .authors)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        publicationYear = try c.decodeIfPresent(Int.self, forKey: .publicationYear)
        if let tags = try c.decodeIfPresent([String].self, forKey: .tags) {
            self.tags = tags
        } else if let legacy = try c.decodeIfPresent([String].self, forKey: .legacyTags) {
            // Older archives exported the labels as `genres`.
            self.tags = legacy
        } else {
            self.tags = []
        }
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        coverImageURL = try c.decodeIfPresent(String.self, forKey: .coverImageURL)
        coverImageFile = try c.decodeIfPresent(String.self, forKey: .coverImageFile)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        bookDescription = try c.decodeIfPresent(String.self, forKey: .bookDescription)
        descriptionSource = try c.decodeIfPresent(String.self, forKey: .descriptionSource)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        physicalLocation = try c.decodeIfPresent(String.self, forKey: .physicalLocation)
        status = try c.decode(String.self, forKey: .status)
        acquiredDate = try c.decodeIfPresent(Date.self, forKey: .acquiredDate)
        purchasePrice = try c.decodeIfPresent(Double.self, forKey: .purchasePrice)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        loanedTo = try c.decodeIfPresent(String.self, forKey: .loanedTo)
        loanedDate = try c.decodeIfPresent(Date.self, forKey: .loanedDate)
        ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID)
        sharedLibraryID = try c.decodeIfPresent(String.self, forKey: .sharedLibraryID)
        isPersonal = try c.decode(Bool.self, forKey: .isPersonal)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        syncState = try c.decode(String.self, forKey: .syncState)
        syncUpdatedAt = try c.decode(Date.self, forKey: .syncUpdatedAt)
        syncDeviceID = try c.decode(String.self, forKey: .syncDeviceID)
        shelves = try c.decodeIfPresent([String].self, forKey: .shelves)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(isbn, forKey: .isbn)
        try c.encodeIfPresent(publicationYear, forKey: .publicationYear)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(coverImageURL, forKey: .coverImageURL)
        try c.encodeIfPresent(coverImageFile, forKey: .coverImageFile)
        try c.encodeIfPresent(publisher, forKey: .publisher)
        try c.encodeIfPresent(pageCount, forKey: .pageCount)
        try c.encodeIfPresent(bookDescription, forKey: .bookDescription)
        try c.encodeIfPresent(descriptionSource, forKey: .descriptionSource)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(physicalLocation, forKey: .physicalLocation)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(acquiredDate, forKey: .acquiredDate)
        try c.encodeIfPresent(purchasePrice, forKey: .purchasePrice)
        try c.encodeIfPresent(rating, forKey: .rating)
        try c.encodeIfPresent(loanedTo, forKey: .loanedTo)
        try c.encodeIfPresent(loanedDate, forKey: .loanedDate)
        try c.encodeIfPresent(ownerID, forKey: .ownerID)
        try c.encodeIfPresent(sharedLibraryID, forKey: .sharedLibraryID)
        try c.encode(isPersonal, forKey: .isPersonal)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(syncState, forKey: .syncState)
        try c.encode(syncUpdatedAt, forKey: .syncUpdatedAt)
        try c.encode(syncDeviceID, forKey: .syncDeviceID)
        try c.encodeIfPresent(shelves, forKey: .shelves)
    }
}

struct NoteDTO: Codable {
    var id: String
    /// The id of the {@link Book} this note belongs to (null = general note).
    var bookID: String?
    var userID: String
    var title: String?
    var content: String
    var noteType: String
    var visibility: String
    var sharedLibraryID: String?
    var pageReference: String?
    var mentions: [String]
    var createdAt: Date
    var updatedAt: Date
    var syncState: String
    var syncUpdatedAt: Date
    var syncDeviceID: String

    init(model: Note) {
        id = model.id
        bookID = model.book?.id
        userID = model.userID
        title = model.title
        content = model.content
        noteType = model.noteType
        visibility = model.visibility
        sharedLibraryID = model.sharedLibraryID
        pageReference = model.pageReference
        mentions = model.mentions
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        syncState = model.syncState
        syncUpdatedAt = model.syncUpdatedAt
        syncDeviceID = model.syncDeviceID
    }
}

struct ReadingListDTO: Codable {
    var id: String
    var name: String
    var listDescription: String?
    var ownerID: String
    var sharedLibraryID: String?
    var isPrivate: Bool
    var createdAt: Date
    var updatedAt: Date
    var syncState: String
    var syncUpdatedAt: Date
    var syncDeviceID: String

    init(model: ReadingList) {
        id = model.id
        name = model.name
        listDescription = model.listDescription
        ownerID = model.ownerID
        sharedLibraryID = model.sharedLibraryID
        isPrivate = model.isPrivate
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        syncState = model.syncState
        syncUpdatedAt = model.syncUpdatedAt
        syncDeviceID = model.syncDeviceID
    }
}

struct ReadingListItemDTO: Codable {
    var id: String
    /// Id of the {@link ReadingList} this item belongs to.
    var listID: String?
    /// Id of the {@link Book} this item references.
    var bookID: String?
    var addedByID: String?
    var position: Int
    var priority: String
    var targetDate: Date?
    var createdAt: Date
    var syncState: String
    var syncUpdatedAt: Date
    var syncDeviceID: String

    init(model: ReadingListItem) {
        id = model.id
        listID = model.list?.id
        bookID = model.book?.id
        addedByID = model.addedByID
        position = model.position
        priority = model.priority
        targetDate = model.targetDate
        createdAt = model.createdAt
        syncState = model.syncState
        syncUpdatedAt = model.syncUpdatedAt
        syncDeviceID = model.syncDeviceID
    }
}

struct ConnectionDTO: Codable {
    var id: String
    /// Ids of the two {@link Book} objects being connected.
    var book1ID: String?
    var book2ID: String?
    var connectionType: String
    var connectionDescription: String?
    var createdByID: String?
    var sharedLibraryID: String?
    var createdAt: Date
    var syncState: String
    var syncUpdatedAt: Date
    var syncDeviceID: String

    init(model: Connection) {
        id = model.id
        book1ID = model.book1?.id
        book2ID = model.book2?.id
        connectionType = model.connectionType
        connectionDescription = model.connectionDescription
        createdByID = model.createdByID
        sharedLibraryID = model.sharedLibraryID
        createdAt = model.createdAt
        syncState = model.syncState
        syncUpdatedAt = model.syncUpdatedAt
        syncDeviceID = model.syncDeviceID
    }
}
