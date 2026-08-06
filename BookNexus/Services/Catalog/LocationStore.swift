import Foundation
import Observation

/// Stores the known set of physical locations for books.
/// Persisted to UserDefaults so it survives launches.
@Observable
final class LocationStore {
    private static let storageKey = "booknexus.locations"

    /// Default suggested locations.
    static let defaults = [
        "Upstairs", "Scott's Office", "Downstairs", "Living Room",
        "Library", "Borrowed", "Storage",
    ]

    var locations: [String]

    init() {
        if let saved = UserDefaults.standard.array(forKey: LocationStore.storageKey) as? [String] {
            locations = saved
        } else {
            locations = LocationStore.defaults
            persist()
        }
    }

    /// Adds a location if not already present (case-insensitive). Returns the canonical name.
    @discardableResult
    func add(_ location: String) -> String {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let existing = locations.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        locations.append(trimmed)
        persist()
        return trimmed
    }

    func remove(_ location: String) {
        locations.removeAll { $0 == location }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(locations, forKey: LocationStore.storageKey)
    }
}
