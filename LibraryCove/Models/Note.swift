import Foundation
import SwiftData

/// Book note/reflection — ported from backend `Note`.
@Model
final class Note {
    var id: String = UUID().uuidString
    /// Owning library (`Library.id`). nil = the pre-multi-library era
    /// (migrated to the default library at launch).
    var libraryID: String?
    var book: Book?
    var userID: String = ""
    var title: String?
    var content: String = ""
    var noteType: String = "general"  // general | takeaway | quote | question | connection
    var visibility: String = "private"  // private | shared | public
    var sharedLibraryID: String?
    var pageReference: String?
    var mentions: [String] = []

    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)

    // Sync metadata
    var syncState: String = "modified"
    var syncUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var syncDeviceID: String = ""

    init(
        id: String = UUID().uuidString,
        book: Book? = nil,
        userID: String,
        title: String? = nil,
        content: String,
        noteType: String = "general",
        visibility: String = "private",
        sharedLibraryID: String? = nil,
        pageReference: String? = nil,
        mentions: [String] = [],
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        syncState: String = "modified",
        syncUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        syncDeviceID: String = ""
    ) {
        self.id = id
        self.book = book
        self.userID = userID
        self.title = title
        self.content = content
        self.noteType = noteType
        self.visibility = visibility
        self.sharedLibraryID = sharedLibraryID
        self.pageReference = pageReference
        self.mentions = mentions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncState = syncState
        self.syncUpdatedAt = syncUpdatedAt
        self.syncDeviceID = syncDeviceID
    }
}

/// Note type enum mirroring backend `NoteType`.
enum NoteType: String, Codable, CaseIterable {
    case general = "general"
    case takeaway = "takeaway"
    case quote = "quote"
    case question = "question"
    case connection = "connection"

    init?(raw: String) {
        self.init(rawValue: raw)
    }
}

/// Visibility enum mirroring backend `NoteVisibility`.
enum NoteVisibility: String, Codable, CaseIterable {
    case `private` = "private"
    case shared = "shared"
    case `public` = "public"

    init?(raw: String) {
        self.init(rawValue: raw)
    }
}
