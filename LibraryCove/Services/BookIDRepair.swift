import Foundation
import SwiftData

/// Repairs duplicate `Book.id` values in the local store.
///
/// Rows can share an id when merge imports re-inserted an archive that
/// already existed locally (older versions didn't dedupe book ids).
/// Duplicate ids break copy discrimination on delete (the form can't tell
/// which copy was picked) and make id-based stale-snapshot guards hide
/// surviving rows.
///
/// For each id shared by multiple rows, the OLDEST row (by createdAt, then
/// PersistentIdentifier) keeps the id — matching BookMastering's "oldest is
/// the master" rule — and every other row is reassigned a fresh UUID. Cover
/// files are re-keyed so the reassigned rows keep their images.
enum BookIDRepair {
    @MainActor
    static func repairIfNeeded(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<Book>()) else { return }
        // Group rows by id; only duplicated ids need work.
        var byID: [String: [Book]] = [:]
        for book in all where !book.id.isEmpty {
            byID[book.id, default: []].append(book)
        }

        var changed = false
        for (_, rows) in byID where rows.count > 1 {
            // Keep the oldest copy as the id owner (same rule as mastering).
            let sorted = rows.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.persistentModelID.hashValue < rhs.persistentModelID.hashValue
            }
            for duplicate in sorted.dropFirst() {
                let oldID = duplicate.id
                let newID = UUID().uuidString
                duplicate.id = newID
                duplicate.updatedAt = Date()
                // Re-key the cover file so the image stays with the row.
                if let bytes = CoverImageStore.data(forBookID: oldID) {
                    CoverImageStore.delete(forBookID: oldID)
                    CoverImageStore.save(bytes, forBookID: newID)
                    if duplicate.coverImageURL == CoverImageStore.zipEntryName(forBookID: oldID) {
                        duplicate.coverImageURL = CoverImageStore.zipEntryName(forBookID: newID)
                    }
                }
                changed = true
            }
        }

        if changed {
            try? context.save()
        }
    }
}
