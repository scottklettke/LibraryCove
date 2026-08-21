import Foundation
import Observation

/// Stores the known, manually-created shelf names for books. Persisted to
/// UserDefaults so it survives launches; there is no AI involvement — shelves
/// are created and curated by the user.
@Observable
final class ShelfStore {
    private static let storageKey = "booknexus.shelves"

    var shelves: [String]

    init() {
        if let saved = UserDefaults.standard.array(forKey: ShelfStore.storageKey) as? [String] {
            shelves = saved
        } else {
            shelves = []
        }
    }

    /// Adds a shelf name if not already present (case-insensitive). Returns the
    /// canonical name, or "" when the input is blank.
    @discardableResult
    func add(_ shelf: String) -> String {
        let trimmed = shelf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let existing = shelves.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        shelves.append(trimmed)
        persist()
        return trimmed
    }

    func remove(_ shelf: String) {
        shelves.removeAll { $0 == shelf }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(shelves, forKey: ShelfStore.storageKey)
    }
}
