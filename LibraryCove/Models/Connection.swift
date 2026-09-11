import Foundation
import SwiftData

/// Knowledge-graph connection between two books — ported from backend `Connection`.
@Model
final class Connection {
    var id: String = UUID().uuidString
    var book1: Book?
    var book2: Book?
    var connectionType: String = "similar_to"  // inspired_by | expands_on | contrasts_with | similar_to
    var connectionDescription: String?  // note: "description" conflicts with the Model macro
    var createdByID: String?
    var sharedLibraryID: String?

    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)

    // Sync metadata
    var syncState: String = "modified"
    var syncUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var syncDeviceID: String = ""

    init(
        id: String = UUID().uuidString,
        book1: Book? = nil,
        book2: Book? = nil,
        connectionType: String = "similar_to",
        connectionDescription: String? = nil,
        createdByID: String? = nil,
        sharedLibraryID: String? = nil,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        syncState: String = "modified",
        syncUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        syncDeviceID: String = ""
    ) {
        self.id = id
        self.book1 = book1
        self.book2 = book2
        self.connectionType = connectionType
        self.connectionDescription = connectionDescription
        self.createdByID = createdByID
        self.sharedLibraryID = sharedLibraryID
        self.createdAt = createdAt
        self.syncState = syncState
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeviceID = syncDeviceID
    }
}

/// Connection type enum mirroring backend `ConnectionType`.
enum ConnectionType: String, Codable, CaseIterable {
    case inspiredBy = "inspired_by"
    case expandsOn = "expands_on"
    case contrastsWith = "contrasts_with"
    case similarTo = "similar_to"

    init?(raw: String) {
        self.init(rawValue: raw)
    }
}
