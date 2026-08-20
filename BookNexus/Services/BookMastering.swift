import Foundation

/// Master-copy selection: a book title stored as several copies (same
/// normalized ISBN) must appear once in the main library list. The "master" is
/// the oldest added copy; every other copy is reachable only through the
/// detail view's Copies section. Books without an ISBN are unique (never
/// grouped) and always shown.
enum BookMastering {

    /// One representative copy per normalized ISBN (the oldest added copy —
    /// independent of the input order), plus every ISBN-less book, in the
    /// caller's order.
    static func masters(of books: [Book]) -> [Book] {
        var byISBN: [String: Book] = [:]
        for book in books {
            guard let normalized = Book.normalizedISBN(book.isbn) else { continue }
            if let current = byISBN[normalized], current.createdAt <= book.createdAt { continue }
            byISBN[normalized] = book
        }
        var shown = Set<String>()
        var result: [Book] = []
        for book in books {
            if let normalized = Book.normalizedISBN(book.isbn) {
                // Only the oldest copy is a master; each appears once.
                guard byISBN[normalized]?.id == book.id, shown.insert(normalized).inserted else { continue }
            }
            result.append(book)
        }
        return result
    }

    /// Number of copies stored per normalized ISBN (for the "N copies" badge).
    /// Only ISBN-bearing books are counted.
    static func copyCounts(byISBN books: [Book]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for book in books {
            guard let normalized = Book.normalizedISBN(book.isbn) else { continue }
            counts[normalized, default: 0] += 1
        }
        return counts
    }

    /// Sibling copies sharing `isbn`'s normalized form (excluding the given
    /// book), or sharing the title when no ISBN exists — used by the detail
    /// view's Copies section.
    static func otherCopies(of book: Book, in books: [Book]) -> [Book] {
        if let normalized = Book.normalizedISBN(book.isbn) {
            return books.filter {
                $0.id != book.id && Book.normalizedISBN($0.isbn) == normalized
            }
        }
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty else { return [] }
        return books.filter {
            $0.id != book.id &&
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title
        }
    }
}
