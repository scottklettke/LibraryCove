import Foundation

/// One model-generated rule mapping a raw stored genre tag to one or more
/// canonical shelf categories ("Fiction", "Non-fiction", "History", …).
struct GenreTagMapping: Codable, Equatable {
    let tag: String
    let categories: [String]
}

/// A validated shelf-categorization plan: how every observed genre tag maps to
/// canonical categories. `fingerprint` is derived from the exact (normalized,
/// unique) tag set the plan was built from, so a plan is instantly detected as
/// stale when the library gains or renames genres and can be regenerated.
struct ShelfCategoryPlan: Codable, Equatable {
    var mappings: [GenreTagMapping]
    var fingerprint: String
    var createdAt: Date
}

/// AI-driven canonical shelf categories. The user asked for "Group by genre"
/// to organize by the main category of a book (Fiction, Non-fiction, History,
/// Children's …). The model proposes the taxonomy from the library each run —
/// there is no fixed canon — and maps every observed tag onto one or more
/// categories. The plan is re-runnable as the library grows; staleness is
/// detected by fingerprint, not by time.
enum ShelfCategorizer {

    static let maxSnapshotLines = 80

    private static let storageKey = "shelfCategoryPlan"

    // MARK: - Inputs

    /// Every non-empty raw genre tag in the library, trimmed, original case.
    static func allGenres(from books: [Book]) -> [String] {
        books.flatMap(\.genres)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `tag: count` lines for the model (lowercased tokens, count desc then
    /// alphabetically, capped) — the same shape the genre-cleanup feature uses,
    /// so both features reason over identical input.
    static func snapshot(from books: [Book]) -> String {
        var counts: [String: Int] = [:]
        for tag in allGenres(from: books) {
            counts[tag.lowercased(), default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(maxSnapshotLines)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    /// Stable identifier for a set of genres: a deterministic canonical encoding
    /// of the normalized unique tags (base64 of the UTF-8 sorted list joined by
    /// a unit separator). Content-addressed, so it is reproducible across
    /// launches and injectable in tests.
    static func fingerprint(of tags: [String]) -> String {
        let normalized = Set(
            tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let canonical = normalized.sorted().joined(separator: "\u{1}")
        return Data(canonical.utf8).base64EncodedString()
    }

    /// Whether a stored plan is still derived from the exact current tag set.
    static func isValid(_ plan: ShelfCategoryPlan, forTags tags: [String]) -> Bool {
        plan.fingerprint == fingerprint(of: tags)
    }

    // MARK: - Prompt

    static func prompt(snapshot: String) -> String {
        """
        These are the genre tags currently stored in a personal book library, as "tag: how many books":

        \(snapshot)

        Design a small set of top-level shelf categories that honestly cover THIS library's tags —
        for example Fiction, Non-fiction, History, Children's, Science Fiction & Fantasy, Mystery & Thriller,
        Romance, Reference & Study. Reuse exact category-name spellings across every tag so equivalent tags
        coalesce into one shelf, keep the total category count between 4 and 12, and do not invent categories
        that nothing maps to.

        Then map EVERY tag to one or more of those categories — a book may legitimately belong to several
        shelves. Treat placeholder tags ("none", "unknown", "--", junk) by mapping them to an "Other" category.
        Keep category names and tag values in Title Case.

        Return ONLY a valid JSON array, with no prose and no markdown fences, each element shaped exactly as:
        {"tag": "exact lowercased library tag", "categories": ["Category One", "Category Two"]}
        """
    }

    // MARK: - Parsing

    static func parseMappings(from data: Data) throws -> [GenreTagMapping] {
        // Tolerant on purpose: the input is free-form model output, so one
        // malformed row (missing key, empty tag, empty categories) must be
        // skipped rather than fail the whole plan.
        let json = try JSONSerialization.jsonObject(with: data)
        guard let rows = json as? [[String: Any]] else { return [] }
        var seenTags = Set<String>()
        var out: [GenreTagMapping] = []
        for row in rows {
            guard let tagValue = row["tag"] as? String else { continue }
            let tag = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            let tagKey = tag.lowercased()
            guard !seenTags.contains(tagKey) else { continue }
            seenTags.insert(tagKey)

            guard let rawCategories = row["categories"] as? [String] else { continue }
            var categories: [String] = []
            var seenCategories = Set<String>()
            for raw in rawCategories {
                let cat = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cat.isEmpty else { continue }
                let catKey = cat.lowercased()
                guard !seenCategories.contains(catKey) else { continue }
                seenCategories.insert(catKey)
                categories.append(cat)
            }
            guard !categories.isEmpty else { continue }
            out.append(GenreTagMapping(tag: tag, categories: categories))
        }
        return out
    }

    // MARK: - Generation

    struct EmptyPlanError: LocalizedError {
        var errorDescription: String? { "The model returned no usable categories." }
    }

    /// Runs the full pipeline: snapshot → model → parse → fingerprint.
    /// An empty library yields an empty plan (no model call).
    static func generatePlan(books: [Book]) async throws -> ShelfCategoryPlan {
        let tags = allGenres(from: books)
        let empty = ShelfCategoryPlan(mappings: [], fingerprint: fingerprint(of: tags), createdAt: Date())
        guard !tags.isEmpty else { return empty }

        let response = try await AIService.shared.generate(
            AIPrompt(
                system: "You are a careful book-cataloging assistant. Respond with only valid JSON and nothing else.",
                user: prompt(snapshot: snapshot(from: books))
            )
        )
        let mappings = try parseMappings(from: Data(response.utf8))
        guard !mappings.isEmpty else { throw EmptyPlanError() }
        return ShelfCategoryPlan(mappings: mappings, fingerprint: fingerprint(of: tags), createdAt: Date())
    }

    // MARK: - Shelf building

    /// Builds ordered shelf sections from a plan. Every book appears under each
    /// of its mapped categories (multi-membership — the user's chosen behavior);
    /// books whose tags map nowhere are collected into a trailing "Other"
    /// section so no book is unreachable. Returns nil when there is no usable
    /// plan (the caller falls back to raw-tag grouping).
    static func shelfSections(books: [Book], plan: ShelfCategoryPlan?) -> [(category: String, books: [Book])]? {
        guard let plan, !plan.mappings.isEmpty else { return nil }
        var byTag: [String: [String]] = [:]
        for mapping in plan.mappings {
            let key = mapping.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            let cats = mapping.categories
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cats.isEmpty else { continue }
            // First mapping for a tag wins; later duplicates are ignored.
            if byTag[key] == nil { byTag[key] = cats }
        }

        var members: [String: [Book]] = [:]
        var other: [Book] = []
        for book in books {
            var matched = Set<String>()
            for raw in book.genres {
                let genre = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !genre.isEmpty else { continue }
                guard let cats = byTag[genre.lowercased()], !cats.isEmpty else { continue }
                for cat in cats {
                    guard !matched.contains(cat) else { continue }
                    matched.insert(cat)
                    members[cat, default: []].append(book)
                }
            }
            if matched.isEmpty { other.append(book) }
        }

        var sections = members
            .map { (category: $0.key, books: $0.value) }
            .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
        if !other.isEmpty { sections.append((category: "Other", books: other)) }
        return sections
    }

    // MARK: - Persistence

    static func storedPlan(in defaults: UserDefaults = .standard) -> ShelfCategoryPlan? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ShelfCategoryPlan.self, from: data)
    }

    static func store(_ plan: ShelfCategoryPlan, in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(plan) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
