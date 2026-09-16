import Foundation
import SwiftData

/// Retired from the launch sequence: it grouped rows by normalized ISBN or
/// title+authors and deleted extras — but duplicate copies of a book are
/// now legitimate data (provider switches and restores copy 1:1 via
/// LibraryDataService.copyArchive, commit 6951982), and this repair
/// silently deleted them on the next launch. Its original trigger can no
/// longer occur: pre-merge switching ran deleteAll + re-insert and CloudKit
/// synced the old rows back down, but the current switch engine never
/// deleteAlls (copyArchive skips already-present ids instead).
///
/// Kept for manual cleanup of legacy-flooded stores ONLY — invoke
/// deliberately, never from a launch path.
enum BookDuplicateRepair {
    @MainActor
    static func repairIfNeeded(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<Book>()), all.count > 1 else { return }

        var groups: [String: [Book]] = [:]
        for book in all {
            let key: String
            if let isbn = Book.normalizedISBN(book.isbn) {
                key = "isbn:\(isbn)"
            } else {
                let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !title.isEmpty else { continue }
                key = "title:\(title)|\(book.authors.map { $0.lowercased() }.sorted().joined(separator: "|"))"
            }
            groups[key, default: []].append(book)
        }

        var changed = false
        for (_, rows) in groups where rows.count > 1 {
            let sorted = rows.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.persistentModelID.hashValue < rhs.persistentModelID.hashValue
            }
            let keeper = sorted[0]
            for duplicate in sorted.dropFirst() {
                absorb(duplicate: duplicate, into: keeper, context: context)
                changed = true
            }
        }

        if changed {
            try? context.save()
        }
    }

    /// Moves the duplicate's relationships onto the keeper, fills blank
    /// keeper fields from the duplicate, keeps the better cover, then
    /// deletes the duplicate row (its cover file too, if the keeper didn't
    /// need re-keying).
    private static func absorb(duplicate: Book, into keeper: Book, context: ModelContext) {
        // Re-point relationships.
        for note in duplicate.notes ?? [] { note.book = keeper }
        for item in duplicate.listItems ?? [] { item.book = keeper }
        for connection in duplicate.connectionsAsBook1 ?? [] { connection.book1 = keeper }
        for connection in duplicate.connectionsAsBook2 ?? [] { connection.book2 = keeper }
        keeper.notes = (keeper.notes ?? []) + (duplicate.notes ?? [])
        keeper.listItems = (keeper.listItems ?? []) + (duplicate.listItems ?? [])
        keeper.connectionsAsBook1 = (keeper.connectionsAsBook1 ?? []) + (duplicate.connectionsAsBook1 ?? [])
        keeper.connectionsAsBook2 = (keeper.connectionsAsBook2 ?? []) + (duplicate.connectionsAsBook2 ?? [])

        // Merge tags/shelves (union preserves both sets).
        keeper.tags = Array(Set(keeper.tags).union(duplicate.tags)).sorted()
        keeper.shelves = Array(Set(keeper.shelves).union(duplicate.shelves)).sorted()

        // Fill blanks; never overwrite user data with empties.
        if keeper.bookDescription == nil || keeper.bookDescription?.isEmpty == true {
            keeper.bookDescription = duplicate.bookDescription
            keeper.descriptionSource = duplicate.descriptionSource
        }
        if keeper.series == nil { keeper.series = duplicate.series }
        if keeper.physicalLocation == nil { keeper.physicalLocation = duplicate.physicalLocation }
        if keeper.genre == nil { keeper.genre = duplicate.genre }
        if keeper.language == nil { keeper.language = duplicate.language }
        if keeper.publisher == nil { keeper.publisher = duplicate.publisher }
        if keeper.pageCount == nil { keeper.pageCount = duplicate.pageCount }
        if keeper.publicationYear == nil { keeper.publicationYear = duplicate.publicationYear }
        if keeper.isbn == nil { keeper.isbn = duplicate.isbn }
        if keeper.olKey == nil { keeper.olKey = duplicate.olKey }
        if keeper.rating == nil { keeper.rating = duplicate.rating }
        if keeper.acquiredDate == nil { keeper.acquiredDate = duplicate.acquiredDate }

        // Prefer a local cover over a remote URL; prefer any cover over none.
        let keeperCover = keeper.coverImageURL
        let duplicateCover = duplicate.coverImageURL
        if keeperCover == nil || (keeperCover?.hasPrefix("http") == true && duplicateCover?.hasPrefix("data:") == true) {
            keeper.coverImageURL = duplicateCover
        }

        // Covers on disk: if the duplicate had a file and the keeper didn't,
        // move the file under the keeper's id.
        if CoverImageStore.data(forBookID: keeper.id) == nil,
           let bytes = CoverImageStore.data(forBookID: duplicate.id) {
            CoverImageStore.save(bytes, forBookID: keeper.id)
            keeper.coverImageURL = CoverImageStore.zipEntryName(forBookID: keeper.id)
        }

        duplicate.coverImageURL = nil
        context.delete(duplicate)
        CoverImageStore.delete(forBookID: duplicate.id)
        keeper.updatedAt = Date()
    }
}
