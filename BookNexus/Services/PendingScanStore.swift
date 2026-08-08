import Foundation

/// Persists scanned-but-not-yet-processed catalog books so they survive
/// app crashes or early dismissal. Backed by a JSON blob in UserDefaults.
struct PendingScanStore {
    private static let key = "pendingScannedBooks"

    static func load() -> [CatalogBook] {
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
