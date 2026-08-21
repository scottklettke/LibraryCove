import Foundation
import SwiftData

/// Repairs books created with the legacy "never set" `createdAt`/`updatedAt`
/// sentinel — `Date(timeIntervalSinceReferenceDate: 0)`, which is 2001‑01‑01
/// UTC and renders as 12/31/00 in negative-offset timezones. New inserts now
/// always stamp a real date; this cleans up books that were stored before the
/// fix. Idempotent and bounded, so it is safe to run on every launch: only
/// books whose timestamps sit within a day of the epoch are touched.
enum BookDateRepair {

    /// Best-effort `createdAt` for a book whose stored dates are sentinel
    /// dates. Prefers the real last-updated time as the most recent reliable
    /// point this book actually existed, else the current time.
    private static let sentinel = Date(timeIntervalSinceReferenceDate: 0)
    private static let window = TimeInterval(86_400)

    static func isSentinel(_ date: Date) -> Bool {
        abs(date.timeIntervalSince(sentinel)) < window
    }

    static func repairSentinelDates(books: [Book], context: ModelContext) {
        var changed = false
        for book in books {
            let createdAtSentinel = isSentinel(book.createdAt)
            let updatedAtSentinel = isSentinel(book.updatedAt)
            guard createdAtSentinel || updatedAtSentinel else { continue }
            let restored = updatedAtSentinel ? Date() : book.updatedAt
            if createdAtSentinel { book.createdAt = restored }
            if updatedAtSentinel { book.updatedAt = restored }
            changed = true
        }
        if changed { try? context.save() }
    }
}
