import Foundation
import SwiftData

/// One model-proposed fiction/non-fiction classification for a book.
struct BookKindProposal: Codable, Equatable {
    /// The `Book.id` the model was asked to classify.
    let bookID: String
    /// Normalized `BookKind.rawValue` — "fiction" or "non-fiction". nil when
    /// the model couldn't decide (the book stays unclassified).
    var kind: String?
}

/// AI fiction/non-fiction classification, offered as a review list the user
/// approves before anything is written. Pure, testable logic: builds a
/// book-level snapshot, asks the model for per-book proposals, validates the
/// model's JSON, and applies the approved subset to `Book.kind`.
///
/// The model classifies from each book's title/authors (tags are often
/// ambiguous or missing), so books with no tags can still be labeled, and
/// the user sees every proposal before it lands on a book.
enum FictionClassifier {

    static let maxLines = 200

    // MARK: - Input

    /// One line per book: `ID :: Title :: Authors :: tags`. The ID is opaque
    /// to the user but lets the model reference books in its JSON.
    static func snapshot(from books: [Book]) -> String {
        books.prefix(maxLines).map { book in
            let title = book.title.isEmpty ? "(untitled)" : book.title
            let tags = book.tags.isEmpty ? "" : "; tags: \(book.tags.joined(separator: ", "))"
            return "\(book.id) :: \(title) :: \(book.authorsText)\(tags)"
        }.joined(separator: "\n")
    }

    static func prompt(snapshot: String) -> String {
        """
        These are books in a personal library, one per line as:
        <id> :: <title> :: <authors>; tags: <tags>

        \(snapshot)

        Classify EVERY line as either Fiction or Non-fiction, based only on the information given
        (a fantasy/romance/thriller/historical-novel is Fiction; history/biography/science/gardening/
        how-to is Non-fiction). A book that is genuinely ambiguous may be left out (omit its id).

        Return ONLY a valid JSON array, no prose and no markdown fences, each element shaped exactly as:
        {"bookID": "<exact id from the input>", "kind": "fiction"}
        with "kind" being exactly "fiction" or "non-fiction".
        """
    }

    // MARK: - Parsing

    static func parseProposals(from data: Data) throws -> [BookKindProposal] {
        // Tolerant by design: free-form model output; one malformed row must not
        // fail the whole list. Also recovers from truncated JSON arrays.
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        guard let rows = reparsedArray(from: text) else { return [] }
        var out: [BookKindProposal] = []
        for row in rows {
            guard let id = (row["bookID"] as? String).map({
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }), !id.isEmpty else { continue }
            let rawKind = (row["kind"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let kind = rawKind.flatMap { BookKind(rawValue: $0) }
                .flatMap { $0 == .notSet ? nil : $0 }
                .map(\.rawValue)
            out.append(BookKindProposal(bookID: id, kind: kind))
        }
        return out
    }

    private static func reparsedArray(from text: String) -> [[String: Any]]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("[") else { return nil }
        func parse(_ s: String) -> [[String: Any]]? {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else { return nil }
            return obj as? [[String: Any]]
        }
        if let direct = parse(trimmed) { return direct }
        var candidate = trimmed
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

    // MARK: - Validation

    /// Only keep proposals that reference real, unclassified books, and never
    /// overwrite a kind the user set by hand (proposals only target unset books).
    static func matching(_ proposals: [BookKindProposal], to books: [Book]) -> [(book: Book, kind: String)] {
        var byID: [String: Book] = [:]
        for book in books where byID[book.id] == nil { byID[book.id] = book }
        var out: [(book: Book, kind: String)] = []
        for proposal in proposals {
            guard let kind = proposal.kind, let book = byID[proposal.bookID] else { continue }
            guard book.kind.isEmpty else { continue } // never overwrite a user-set kind
            out.append((book, kind))
        }
        return out
    }

    /// Applies proposals, returns how many books changed. Saves once.
    @discardableResult
    static func apply(_ proposals: [BookKindProposal], to books: [Book], context: ModelContext) -> Int {
        let matched = matching(proposals, to: books)
        guard !matched.isEmpty else { return 0 }
        for (book, kind) in matched {
            book.kind = kind
        }
        try? context.save()
        return matched.count
    }

    // MARK: - Generation

    static func generateProposals(books: [Book]) async throws -> [BookKindProposal] {
        let unclassified = books.filter { $0.kind.isEmpty }
        guard !unclassified.isEmpty else { return [] }
        let response = try await AIService.shared.generate(
            AIPrompt(
                system: "You are a careful book-cataloging assistant. Respond with only valid JSON and nothing else.",
                user: prompt(snapshot: snapshot(from: unclassified))
            )
        )
        return try parseProposals(from: Data(response.text.utf8))
    }
}
