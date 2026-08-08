import Foundation
import Observation

/// Stores the known set of genres/categories for books.
/// Persisted to UserDefaults so it survives launches.
@Observable
final class GenreStore {
    private static let storageKey = "booknexus.genres"

    /// Default suggested genres/categories.
    static let defaults = [
        "Fiction", "Nonfiction", "Science", "History", "Biography",
        "Fantasy", "Sci-Fi", "Mystery", "Romance", "Thriller",
    ]

    var genres: [String]

    init() {
        if let saved = UserDefaults.standard.array(forKey: GenreStore.storageKey) as? [String] {
            genres = saved
        } else {
            genres = GenreStore.defaults
            persist()
        }
    }

    /// Adds a genre if not already present (case-insensitive). Returns the canonical name.
    @discardableResult
    func add(_ genre: String) -> String {
        let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let existing = genres.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        genres.append(trimmed)
        persist()
        return trimmed
    }

    func remove(_ genre: String) {
        genres.removeAll { $0 == genre }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(genres, forKey: GenreStore.storageKey)
    }
}
