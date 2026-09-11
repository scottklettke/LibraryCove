import Foundation

/// A single AI request/connection log entry: which engine, when it ran, the
/// outcome (attempt / success / error), a short human-readable detail, and
/// latency in milliseconds. Persisted so the Settings "AI connection logs"
/// section shows what the API calls looked like even after a relaunch.
struct AILogEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case attempt
        case success
        case error
    }

    let id: UUID
    let date: Date
    let engine: AIEngine
    let kind: Kind
    let detail: String
    let latencyMs: Double?

    init(id: UUID = UUID(), date: Date = Date(), engine: AIEngine, kind: Kind, detail: String, latencyMs: Double? = nil) {
        self.id = id
        self.date = date
        self.engine = engine
        self.kind = kind
        self.detail = detail
        self.latencyMs = latencyMs
    }

    /// e.g. "412 ms". Nil when we didn't time the phase (attempts).
    var latencyText: String? {
        guard let latencyMs, latencyMs > 0 else { return nil }
        return String(format: "%.0f ms", latencyMs)
    }
}

/// A small ring buffer of AI request logs in UserDefaults — no separate file,
/// no extra plumbing; the Settings section just reads it. Appends are
/// best-effort: encode/decode failures are swallowed, never thrown.
enum AILogStore {
    static let maxEntries = 100
    private static let key = "AI.logEntries"

    static func entries() -> [AILogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode([AILogEntry].self, from: data) else {
            return []
        }
        return value
    }

    static func append(_ entry: AILogEntry) {
        var all = entries()
        all.append(entry)
        if all.count > maxEntries {
            all = Array(all.suffix(maxEntries))
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
