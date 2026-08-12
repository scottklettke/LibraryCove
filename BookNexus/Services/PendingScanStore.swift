import Foundation

/// Persists scanned-but-not-yet-processed catalog books so they survive
/// app crashes or early dismissal. Backed by a JSON blob in UserDefaults.
struct PendingScanStore {
    private static let key = "pendingScannedBooks"

    static func load() -> [CatalogBook] {
        // UI-test seam: seed pending scans from the launch environment so
        // deterministic offline tests can exercise the import flow without a
        // camera. Only active when the variable is set by a test.
        if let raw = ProcessInfo.processInfo.environment["UI_TEST_PENDING_SCANS"],
           let data = raw.data(using: .utf8),
           let list = try? JSONDecoder().decode([CatalogBook].self, from: data) {
            return list
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CatalogBook].self, from: data) else {
            return []
        }
        return list
    }

    static func append(_ book: CatalogBook) {
        var list = load()
        list.removeAll { $0.id == book.id }
        list.append(book)
        save(list)
    }

    static func remove(id: String) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var count: Int {
        load().count
    }

    private static func save(_ list: [CatalogBook]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
