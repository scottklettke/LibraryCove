import Foundation
import SwiftData

/// Core book metadata — ported from backend `Book`.
/// IDs are UUID strings (sync-friendly). JSON arrays are stored as `[String]`.
@Model
final class Book {
    @Attribute(.unique) var id: String
    var title: String
    var authors: [String]
    var isbn: String?
    var publicationYear: Int?
    var genres: [String]
    var coverImageURL: String?
    var publisher: String?
    var pageCount: Int?
    var bookDescription: String?
    var descriptionSource: String?  // openlibrary | googlebooks | wikipedia | none
    var language: String?
    var physicalLocation: String?
    var status: String  // reading | to-read | completed | donated
    var acquiredDate: Date?
    var purchasePrice: Double?
    var rating: Int?  // 1–5 stars
    var loanedTo: String?
    var loanedDate: Date?

    // Ownership for multi-user / family support
    var ownerID: String?
    var sharedLibraryID: String?
    var isPersonal: Bool

    var createdAt: Date
    var updatedAt: Date

    // Sync metadata
    var syncState: String  // synced | modified | deleted (tombstone)
    var syncUpdatedAt: Date
    var syncDeviceID: String

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \Note.book)
    var notes: [Note]

    @Relationship(inverse: \ReadingListItem.book)
    var listItems: [ReadingListItem]

    @Relationship(deleteRule: .nullify, inverse: \Connection.book1)
    var connectionsAsBook1: [Connection]

    @Relationship(deleteRule: .nullify, inverse: \Connection.book2)
    var connectionsAsBook2: [Connection]

    init(
        id: String = UUID().uuidString,
        title: String,
        authors: [String] = [],
        isbn: String? = nil,
        publicationYear: Int? = nil,
        genres: [String] = [],
        coverImageURL: String? = nil,
        publisher: String? = nil,
        pageCount: Int? = nil,
        bookDescription: String? = nil,
        descriptionSource: String? = nil,
        language: String? = nil,
        physicalLocation: String? = nil,
        status: String = "to-read",
        acquiredDate: Date? = nil,
        purchasePrice: Double? = nil,
        rating: Int? = nil,
        loanedTo: String? = nil,
        loanedDate: Date? = nil,
        ownerID: String? = nil,
        sharedLibraryID: String? = nil,
        isPersonal: Bool = true,
        createdAt: Date = .init(),
        updatedAt: Date = .init(),
        syncState: String = "modified",
        syncUpdatedAt: Date = .init(),
        syncDeviceID: String = ""
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.isbn = isbn
        self.publicationYear = publicationYear
        self.genres = genres
        self.coverImageURL = coverImageURL
        self.publisher = publisher
        self.pageCount = pageCount
        self.bookDescription = bookDescription
        self.descriptionSource = descriptionSource
        self.language = language
        self.physicalLocation = physicalLocation
        self.status = status
        self.acquiredDate = acquiredDate
        self.purchasePrice = purchasePrice
        self.rating = rating
        self.loanedTo = loanedTo
        self.loanedDate = loanedDate
        self.ownerID = ownerID
        self.sharedLibraryID = sharedLibraryID
        self.isPersonal = isPersonal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncState = syncState
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeviceID = syncDeviceID
        self.notes = []
        self.listItems = []
        self.connectionsAsBook1 = []
        self.connectionsAsBook2 = []
    }
}

extension Book {
    /// Display authors joined by ", ".
    var authorsText: String {
        authors.isEmpty ? "Unknown" : authors.joined(separator: ", ")
    }

    /// Whether this book is currently loaned out.
    var isLoaned: Bool {
        loanedTo != nil && !(loanedTo?.isEmpty ?? true)
    }

    /// Reading status stored as `status` string.
    var statusEnum: BookStatus {
        BookStatus(rawValue: status) ?? .toRead
    }
}

/// Book status enum mirroring backend `BookStatus`.
enum BookStatus: String, Codable, CaseIterable, Identifiable {
    case reading = "reading"
    case toRead = "to-read"
    case completed = "completed"
    case donated = "donated"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reading: return "Reading"
        case .toRead: return "To read"
        case .completed: return "Completed"
        case .donated: return "Donated"
        }
    }

    init?(raw: String) {
        self.init(rawValue: raw)
    }
}
