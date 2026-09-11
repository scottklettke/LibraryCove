import Foundation
import SwiftData

/// Reading list + items — ported from backend `ReadingList` / `ReadingListItem`.
@Model
final class ReadingList {
    var id: String = UUID().uuidString
    var name: String = ""
    var listDescription: String?
    var ownerID: String = ""
    var sharedLibraryID: String?
    var isPrivate: Bool = true

    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)

    // Sync metadata
    var syncState: String = "modified"
    var syncUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var syncDeviceID: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ReadingListItem.list)
    var items: [ReadingListItem]?

    init(
        id: String = UUID().uuidString,
        name: String,
        listDescription: String? = nil,
        ownerID: String,
        sharedLibraryID: String? = nil,
        isPrivate: Bool = true,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        syncState: String = "modified",
        syncUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        syncDeviceID: String = ""
    ) {
        self.id = id
        self.name = name
        self.listDescription = listDescription
        self.ownerID = ownerID
        self.sharedLibraryID = sharedLibraryID
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncState = syncState
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeviceID = syncDeviceID
        self.items = []
    }
}

/// A single book within a reading list (position/priority/target date).
@Model
final class ReadingListItem {
    var id: String = UUID().uuidString
    var list: ReadingList?
    var book: Book?
    var addedByID: String?
    var position: Int = 0
    var priority: String = "normal"  // low | normal | high
    var targetDate: Date?

    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)

    // Sync metadata
    var syncState: String = "modified"
    var syncUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var syncDeviceID: String = ""

    init(
        id: String = UUID().uuidString,
        list: ReadingList? = nil,
        book: Book? = nil,
        addedByID: String? = nil,
        position: Int = 0,
        priority: String = "normal",
        targetDate: Date? = nil,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        syncState: String = "modified",
        syncUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        syncDeviceID: String = ""
    ) {
        self.id = id
        self.list = list
        self.book = book
        self.addedByID = addedByID
        self.position = position
        self.priority = priority
        self.targetDate = targetDate
        self.createdAt = createdAt
        self.syncState = syncState
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeviceID = syncDeviceID
    }
}
