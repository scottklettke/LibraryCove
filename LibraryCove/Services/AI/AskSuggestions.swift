import Foundation

/// Deterministic, instant suggestion chips for the Ask AI chat.
///
/// No model call: chips must appear instantly as the conversation changes,
/// without a network round-trip, and they never pick a model of their own —
/// the selected engine only runs when the user taps one. The empty-chat
/// starters are fixed; once the user has said something, follow-ups are
/// derived from the intent of their last message plus strong library signals
/// (reading status, most common genre, top ratings), so the tray stays
/// relevant to the thread instead of repeating the same three starters.
enum AskSuggestions {

    /// Shown with an empty conversation — general enough to be useful before
    /// anyone has expressed a preference. Also the stable size of the tray.
    static let starters = [
        "What should I read next?",
        "Recommend authors like my favorites",
        "About my current book",
    ]

    /// Follow-up chips for the current conversation and library. Deterministic
    /// and unique; never returns more than `starters.count` chips.
    static func forChat(turns: [AITurn], books: [Book]) -> [String] {
        guard let lastUser = turns.reversed().first(where: { $0.role == .user })?.text,
              !turns.isEmpty else {
            return starters
        }
        let query = lastUser.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return starters }

        var pool: [String] = []

        // Thread continuity: a follow-up tied to what was just asked, so the
        // conversation can deepen rather than restart.
        if query.contains("author") {
            pool.append("Recommend another author I'd like")
        } else if query.contains("read next")
            || query.contains("recommend")
            || query.contains("suggest")
            || query.contains("similar") {
            pool.append("Which of those should I start with?")
        } else if query.contains("theme") {
            pool.append("Break down the main themes of that book")
        } else if query.contains("about") || query.contains("tell me") {
            pool.append("Tell me more about that book")
        }

        // Library-grounded directions — the strongest personal signals first.
        let reading = books
            .filter { $0.status == "reading" }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        if let reading {
            pool.append("Find books similar to “\(reading.title)”")
        }
        if let genre = mostCommonGenre(books) {
            pool.append("Recommend something in \(genre)")
        }
        if books.contains(where: { ($0.rating ?? 0) >= 4 }) {
            pool.append("Recommend books like my top-rated ones")
        }

        // Keep the tray full with safe, useful fallbacks rather than shrinking.
        let fallbacks = [
            "Find a book to match my current mood",
            "Ask another question about my library",
        ]
        for fallback in fallbacks where !pool.contains(fallback) {
            guard pool.count < starters.count else { break }
            pool.append(fallback)
        }

        return Array(pool.prefix(starters.count))
    }

    /// The most common non-empty genre label, deterministically (count
    /// descending, then localized-case-insensitive alpha), matching how the
    /// library snapshot counts tags so the signal stays consistent.
    static func mostCommonGenre(_ books: [Book]) -> String? {
        var counts: [String: (label: String, count: Int)] = [:]
        for book in books {
            for genre in book.tags {
                let cleaned = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let key = cleaned.lowercased()
                var entry = counts[key] ?? (cleaned, 0)
                entry.count += 1
                counts[key] = entry
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .first?.value.label
    }
}
