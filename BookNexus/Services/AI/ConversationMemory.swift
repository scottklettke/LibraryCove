import Foundation

/// Who said a message in the Ask AI conversation.
enum AIRole: String, Codable {
    case user
    case assistant
}

/// A single exchange in the Ask AI conversation, persisted for the local
/// transcript.
struct AITurn: Codable, Equatable {
    let role: AIRole
    let text: String
    let date: Date
}

/// The seam for conversation persistence. Today it's a local transcript file
/// (`LocalTranscriptMemory`); a different memory backend (e.g. cloud sync) can
/// be swapped in later by conforming to this protocol without touching the UI.
protocol ConversationMemory {
    func load() -> [AITurn]
    func append(_ turn: AITurn)
    func clear()
    mutating func isPersistent() -> Bool
    /// The last `limit` turns, in chronological order.
    func window(limit: Int) -> [AITurn]
}

extension ConversationMemory {
    /// Default windowing: read everything and keep the newest `limit` turns.
    /// Backends may override for efficiency.
    func window(limit: Int) -> [AITurn] {
        Array(load().suffix(limit))
    }
}

/// Provides the default memory implementation used by the app.
enum ConversationMemoryFactory {
    static func make() -> any ConversationMemory {
        LocalTranscriptMemory()
    }
}

/// File-backed transcript: JSON `[AITurn]` in Application Support. All file
/// operations are best-effort — a missing or corrupt file reads as `[]` and a
/// failed write keeps the turn in memory rather than crashing.
final class LocalTranscriptMemory: ConversationMemory {

    /// How many turns the on-disk transcript may hold before the oldest are
    /// dropped.
    static let maxStoredTurns = 100

    private let storageURL: URL
    private var cache: [AITurn] = []

    /// - Parameter storageURL: Where the transcript lives. Defaults to
    ///   `<Application Support>/ai-conversation.json`; injectable for tests.
    init(storageURL: URL? = nil) {
        let fallback = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ai-conversation.json")
        self.storageURL = storageURL ?? (fallback ?? URL(fileURLWithPath: "/dev/null"))
        self.cache = Self.read(url: self.storageURL)
    }

    // MARK: - ConversationMemory

    func load() -> [AITurn] {
        cache
    }

    func append(_ turn: AITurn) {
        cache.append(turn)
        if cache.count > Self.maxStoredTurns {
            cache.removeFirst(cache.count - Self.maxStoredTurns)
        }
        // Best-effort persist: keep the in-memory copy even if writing fails.
        Self.write(cache, to: storageURL)
    }

    func clear() {
        cache = []
        try? FileManager.default.removeItem(at: storageURL)
    }

    func isPersistent() -> Bool {
        true
    }

    // MARK: - Transcript access

    /// The last `limit` turns, in chronological order.
    func window(limit: Int = 8) -> [AITurn] {
        Array(cache.suffix(limit))
    }

    // MARK: - File I/O

    private static func read(url: URL) -> [AITurn] {
        guard let data = try? Data(contentsOf: url),
              let turns = try? JSONDecoder().decode([AITurn].self, from: data) else {
            return []
        }
        // Re-clip defensively in case the file was written by an older build.
        let allowed = min(turns.count, maxStoredTurns)
        return Array(turns.suffix(allowed))
    }

    private static func write(_ turns: [AITurn], to url: URL) {
        guard let data = try? JSONEncoder().encode(turns) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
