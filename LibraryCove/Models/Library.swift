import Foundation
import SwiftData

/// A user-created library: a named collection of books (and their notes,
/// reading lists, connections). One library is active at a time; the active
/// one's content is what the app shows, exports, and syncs.
///
/// Data model: `Book`, `Note`, `ReadingList`, `ReadingListItem`, and
/// `Connection` carry a `libraryID` matching the owning library's `id`.
/// Rows predating multi-library support are migrated into the default
/// library at launch (`LibraryScope.migrateIfNeeded`).
@Model
final class Library {
    var id: String = UUID().uuidString
    var name: String = ""
    /// Exactly one library has `isActive == true` (the one the app shows).
    /// CloudKit syncs this flag across devices — the ACTIVE library is a
    /// device-independent choice, like the sync provider.
    var isActive: Bool = false
    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)

    init(id: String = UUID().uuidString,
         name: String,
         isActive: Bool = false,
         createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.createdAt = createdAt
    }
}
