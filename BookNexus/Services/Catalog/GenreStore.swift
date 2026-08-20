import Foundation
import Observation

/// Stores the known set of tags/categories for books.
/// Persisted to UserDefaults so it survives launches.
@Observable
final class GenreStore {
    private static let storageKey = "booknexus.tags"

    /// Default suggested tags/categories.
    static let defaults = [
        "Fiction", "Nonfiction", "Science", "History", "Biography",
        "Fantasy", "Sci-Fi", "Mystery", "Romance", "Thriller",
    ]

    var tags: [String]

    init() {
        if let saved = UserDefaults.standard.array(forKey: GenreStore.storageKey) as? [String] {
            tags = saved
        } else {
            tags = GenreStore.defaults
            persist()
        }
    }

    /// Adds a genre if not already present (case-insensitive). Returns the canonical name.
    @discardableResult
    func add(_ genre: String) -> String {
        let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let existing = tags.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        tags.append(trimmed)
        persist()
        return trimmed
    }

    func remove(_ genre: String) {
        tags.removeAll { $0 == genre }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(tags, forKey: GenreStore.storageKey)
    }
}
