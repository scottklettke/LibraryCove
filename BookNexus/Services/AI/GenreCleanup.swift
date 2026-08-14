import Foundation
import SwiftData

/// One model-driven genre rewrite: replace `from` with `to`, or remove the
/// genre entirely when `to` is nil.
struct GenreSuggestion: Codable, Equatable {
    let from: String
    let to: String?
}

/// Pure, testable logic behind the "Clean up genres" feature: builds a genre
/// snapshot for the model, parses its suggestions, and applies approved
/// rewrites to `Book.genres`.
enum GenreCleanupService {

    /// Normalized genre lines (`lowercased genre: count`) for the model to
    /// reason about. Sorted count desc then alphabetically, capped at 80 lines.
    static func snapshot(from books: [Book]) -> String {
        var counts: [String: Int] = [:]
        for book in books {
            for genre in book.genres {
                let cleaned = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !cleaned.isEmpty else { continue }
                counts[cleaned, default: 0] += 1
            }
        }
        let lines = counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .prefix(80)
            .map { "\($0.key): \($0.value)" }
        return lines.joined(separator: "\n")
    }

    /// The user message asking the model for merge/remove suggestions. The
    /// response must be a JSON array of `{from, to}` objects.
    static func prompt(snapshot: String) -> String {
        """
        Return ONLY a JSON array of {"from":...,"to":...} suggestions to clean these genres. \
        Combine exact synonyms (e.g. Sci-Fi → Science Fiction). Set to to null to remove \
        non-genre placeholders (e.g. 'unknown', 'none', '--'). Keep canonical genre names in \
        Title Case. Only suggest when confident.

        GENRES
        \(snapshot)
        """
    }

    /// Decodes the model's JSON array and post-validates it: drops entries
    /// with an empty `from`, converts an empty-string `to` to nil, dedupes by
    /// lowercased `from`, preserves order.
    static func parseSuggestions(from data: Data) throws -> [GenreSuggestion] {
        let decoded = try JSONDecoder().decode([GenreSuggestion].self, from: data)
        var seen = Set<String>()
        var result: [GenreSuggestion] = []
        for item in decoded {
            let from = item.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { continue }
            var to: String? = item.to?.trimmingCharacters(in: .whitespacesAndNewlines)
            if to?.isEmpty == true { to = nil }
            let key = from.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(GenreSuggestion(from: from, to: to))
        }
        return result
    }

    /// Applies `suggestions` to every book. Matching is case-insensitive on
    /// trimmed genres; a suggestion's `to` replaces the genre (nil drops it);
    /// unmatched genres are kept. Genres are deduped (case-insensitive),
    /// preserving first-seen order. Returns how many books changed; saves once
    /// at the end when anything changed.
    @discardableResult
    static func apply(_ suggestions: [GenreSuggestion], to books: [Book], context: ModelContext) -> Int {
        var renames: [String: String] = [:]
        var removals = Set<String>()
        for suggestion in suggestions {
            let key = suggestion.from.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if let value = suggestion.to?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                renames[key] = value
            } else {
                removals.insert(key)
            }
        }

        var changed = 0
        for book in books {
            var newGenres: [String] = []
            for genre in book.genres {
                let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                if let replacement = renames[key] {
                    newGenres.append(replacement)
                } else if removals.contains(key) {
                    continue // drop this genre
                } else {
                    newGenres.append(genre)
                }
            }

            var seen = Set<String>()
            newGenres = newGenres.filter { seen.insert($0.lowercased()).inserted }

            if newGenres != book.genres {
                book.genres = newGenres
                changed += 1
            }
        }

        if changed > 0 {
            try? context.save()
        }
        return changed
    }
}
