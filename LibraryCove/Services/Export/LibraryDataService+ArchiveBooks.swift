import Foundation
import SwiftData

extension LibraryDataService {
    /// The books inside an archive, decoded and returned newest-first
    /// (`createdAt`). Read-only: nothing is imported. Used by the Backups
    /// page's backup detail (browse what a backup contains before importing).
    static func archiveBooks(data: Data) throws -> [BookDTO] {
        let loaded = try loadArchive(data)
        return loaded.envelope.books.sorted { $0.createdAt > $1.createdAt }
    }
}
