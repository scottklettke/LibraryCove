import Foundation

/// Hands a join key from the librarycove://join URL handler to the
/// joiner sheet: the URL arrives wherever the app was (often Settings),
/// the sheet presents with the invite pre-filled.
@MainActor
final class PearsPendingJoin: ObservableObject {
    static let shared = PearsPendingJoin()

    @Published var pendingKey: String?

    func stash(_ key: String) {
        pendingKey = key
    }

    func consume() -> String? {
        defer { pendingKey = nil }
        return pendingKey
    }
}
