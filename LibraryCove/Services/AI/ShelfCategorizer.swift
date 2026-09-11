import Foundation

/// One model-generated rule mapping a raw stored genre tag to one or more
/// canonical shelf categories ("Fiction", "Non-fiction", "History", …).
struct GenreTagMapping: Codable, Equatable {
    let tag: String
    let categories: [String]
    /// Proposed classification of books carrying this tag: `fiction`,
    /// `non-fiction`, or nil when the model gives no signal. Normalized to the
    /// `BookKind` raw values the app stores.
    var kind: String? = nil
}

/// A validated shelf-categorization plan: how every observed genre tag maps to
/// canonical categories. `fingerprint` is derived from the exact (normalized,
/// unique) tag set the plan was built from, so a plan is instantly detected as
/// stale when the library gains or renames tags and can be regenerated.
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
        books.flatMap(\.tags)
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

    /// Stable identifier for a set of tags: a deterministic canonical encoding
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
        for example Fantasy, Children's, Animals, Books, Science, Mystery & Thriller (do NOT include an
        "Other" category — the app handles unclassified books itself). Reuse exact category-name spellings
        across every tag so equivalent tags coalesce into one shelf, keep the total category count between 4
        and 12, and do not invent categories that nothing maps to.

        Then map EVERY tag to one or more of those categories — a book may legitimately belong to several
        shelves. For every tag also decide whether books with that tag are Fiction or Non-fiction, based on the
        content the tag describes (e.g. "fantasy" → Fiction, "gardening" → Non-fiction). A tag that describes
        fiction and non-fiction alike may use either; when unclear, prefer Non-fiction. Keep category names and
        tag values in Title Case; use exactly "fiction" or "non-fiction" (lowercase) for kind.

        Return ONLY a valid JSON array, with no prose and no markdown fences, each element shaped exactly as:
        {"tag": "exact lowercased library tag", "categories": ["Category One", "Category Two"], "kind": "fiction"}
        """
    }

    // MARK: - Parsing

    /// Parses the model's JSON array, recovering from truncation: when the
    /// payload is cut off mid-element (output-budget exhaustion, or a server
    /// that stops before the closing bracket), a partial trailing element is
    /// dropped and the array is closed with `]`. Complete leading mappings are
    /// kept — a truncated plan still yields working shelves (unmapped tags fall
    /// to "Other") instead of failing the whole feature. Returns nil when no
    /// repair succeeds.
    private static func reparsedJSONArray(from data: Data) -> [[String: Any]]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty, full.hasPrefix("[") else { return nil }

        func parse(_ s: String) -> [[String: Any]]? {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else { return nil }
            return obj as? [[String: Any]]
        }

        if let direct = parse(full) { return direct }

        // Truncation repair. Only positions ending at a complete element
        // boundary (`}` or `]`, after stripping trailing commas) can close the
        // array, so the scan attempts few parses and stops at the longest
        // recoverable prefix.
        var candidate = full
        while !candidate.isEmpty {
            var closed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            while closed.hasSuffix(",") {
                closed = String(closed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if closed.hasSuffix("}") || closed.hasSuffix("]") {
                if let arr = parse(closed + "]") { return arr }
            }
            if candidate == "[" { break }
            candidate = String(candidate.dropLast())
        }
        return nil
    }

    static func parseMappings(from data: Data) throws -> [GenreTagMapping] {
        // Tolerant on purpose: the input is free-form model output, so one
        // malformed row (missing key, empty tag, empty categories) must be
        // skipped rather than fail the whole plan.
        guard let rows = try? reparsedJSONArray(from: data) else { return [] }
        var seenTags = Set<String>()
        var out: [GenreTagMapping] = []
        for row in rows {
            guard let tagValue = row["tag"] as? String else { continue }
            let tag = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            let tagKey = tag.lowercased()
            guard !seenTags.contains(tagKey) else { continue }
            seenTags.insert(tagKey)

            // Accept both the array form and a single string (models sometimes
            // emit one category as a bare string).
            let rawCategories: [String]
            if let array = row["categories"] as? [String] {
                rawCategories = array
            } else if let single = row["categories"] as? String, !single.isEmpty {
                rawCategories = [single]
            } else {
                continue
            }
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
            let kind = (row["kind"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap { BookKind(rawValue: $0) } // "fiction"/"non-fiction", nil otherwise
                .flatMap { $0 == .notSet ? nil : $0 }
                .map(\.rawValue)
            out.append(GenreTagMapping(tag: tag, categories: categories, kind: kind))
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
        let mappings = try parseMappings(from: Data(response.text.utf8))
        guard !mappings.isEmpty else { throw EmptyPlanError() }
        return ShelfCategoryPlan(mappings: mappings, fingerprint: fingerprint(of: tags), createdAt: Date())
    }

    // MARK: - Shelf building

    /// One level of shelf organization: a named section with its books.
    struct ShelfSection {
        let shelf: String
        let books: [Book]
    }

    /// Builds ordered flat shelf sections from a plan (used by the preview).
    /// Every book appears under each of its mapped shelves; books whose tags
    /// map nowhere — or only to a model-emitted "Other" — are collected into a
    /// single trailing "Other" section so every book stays reachable. Returns
    /// nil when there is no usable plan.
    static func shelfSections(books: [Book], plan: ShelfCategoryPlan?) -> [ShelfSection]? {
        guard let plan, !plan.mappings.isEmpty else { return nil }
        let (members, other) = partition(books: books, plan: plan)
        var sections = members
            .map { ShelfSection(shelf: $0.key, books: $0.value) }
            .sorted { $0.shelf.localizedCaseInsensitiveCompare($1.shelf) == .orderedAscending }
        if !other.isEmpty { sections.append(ShelfSection(shelf: "Other", books: other)) }
        return sections
    }

    /// The two-tier organization the user chose: top-level Fiction /
    /// Non-fiction / Uncategorized groups (driven by the stored `Book.kind`),
    /// each containing that library's AI shelves. A book appears under every
    /// shelf its tags map to; unmapped-only books fall to a single "Other"
    /// shelf inside the group for their kind. Returns nil with no usable plan.
    static func twoTierSections(books: [Book], plan: ShelfCategoryPlan?) -> [(top: String, shelves: [ShelfSection])]? {
        guard let plan, !plan.mappings.isEmpty else { return nil }
        let (members, other) = partition(books: books, plan: plan)
        var byTop: [String: [String: [Book]]] = [:]
        var otherByTop: [String: [Book]] = [:]

        func topName(for book: Book) -> String {
            guard let k = BookKind(rawValue: book.kind), k != .notSet else { return "Uncategorized" }
            return k.displayName
        }

        for (shelf, shelfBooks) in members {
            for book in shelfBooks {
                let top = topName(for: book)
                byTop[top, default: [:]][shelf, default: []].append(book)
            }
        }
        for book in other {
            let top = topName(for: book)
            otherByTop[top, default: []].append(book)
        }

        let order = ["Fiction", "Non-fiction", "Uncategorized"]
        var result: [(top: String, shelves: [ShelfSection])] = []
        let tops = Set(byTop.keys).union(otherByTop.keys)
        for top in order where tops.contains(top) {
            var shelves = (byTop[top] ?? [:])
                .map { ShelfSection(shelf: $0.key, books: $0.value) }
                .sorted { $0.shelf.localizedCaseInsensitiveCompare($1.shelf) == .orderedAscending }
            if let others = otherByTop[top], !others.isEmpty {
                shelves.append(ShelfSection(shelf: "Other", books: others))
            }
            result.append((top: top, shelves: shelves))
        }
        return result.isEmpty ? nil : result
    }

    /// Proposed Fiction/Non-fiction for a book, derived from its mapped tags'
    /// kinds (majority; nil when no tag carries a kind). Written into
    /// `Book.kind` by the reorganize action — the user can still override it
    /// in the book form, which is the source of truth for grouping.
    static func proposedKind(for book: Book, plan: ShelfCategoryPlan?) -> BookKind? {
        guard let plan, !plan.mappings.isEmpty else { return nil }
        var counts: [BookKind: Int] = [:]
        for mapping in plan.mappings where mapping.kind != nil {
            guard let value = BookKind(rawValue: mapping.kind!),
                  value != .notSet else { continue }
            let trimmed = mapping.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Only count kinds for tags this book actually carries.
            if book.tags.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed }) {
                counts[value, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return nil }
        // Majority kind; ties prefer non-fiction (cautious default). Only
        // propose when a clear majority exists, else leave the book uncategorized.
        let best = counts.max { a, b in
            if a.value != b.value { return a.value < b.value }
            return a.key == .fiction // non-fiction wins ties
        }!
        let total = counts.values.reduce(0, +)
        guard best.value > total / 2 else { return nil }
        return best.key
    }

    /// Shared partition core: maps each book to its mapped shelves (skipping
    /// model-emitted "Other"), and collects every unmapped book into `other`.
    /// Guarantees at most one "Other" bucket in the whole plan.
    private static func partition(books: [Book], plan: ShelfCategoryPlan)
        -> (members: [String: [Book]], other: [Book]) {
        var byTag: [String: [String]] = [:]
        for mapping in plan.mappings {
            let key = mapping.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            let cats = mapping.categories
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cats.isEmpty else { continue }
            if byTag[key] == nil { byTag[key] = cats }
        }

        var members: [String: [Book]] = [:]
        var other: [Book] = []
        for book in books {
            var matched = Set<String>()
            for raw in book.tags {
                let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty else { continue }
                guard let cats = byTag[tag.lowercased()], !cats.isEmpty else { continue }
                for cat in cats {
                    guard cat.lowercased() != "other" else { continue } // single Other bucket
                    guard !matched.contains(cat) else { continue }
                    matched.insert(cat)
                    members[cat, default: []].append(book)
                }
            }
            if matched.isEmpty { other.append(book) }
        }
        return (members, other)
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
