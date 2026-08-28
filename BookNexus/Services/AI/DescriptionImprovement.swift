import Foundation

/// "Improve description": gather the fullest real description available for a
/// book, then ask the AI to rewrite only that source into a faithful,
/// non-fabricated summary.
enum AIDescriptionImprovement {

    /// Fetches the best real source text for a book: the book's existing
    /// description plus a catalog lookup (OpenLibrary → Google Books, longest
    /// non-empty wins) when the book has an ISBN, otherwise the existing
    /// description alone. Never throws; returns empty only when no source
    /// exists, in which case the callers must not invent a description.
    static func onlineText(for book: Book) async -> (raw: String, source: String?) {
        let existing = book.bookDescription ?? ""
        if let isbn = book.isbn, !isbn.isEmpty {
            let (text, source) = await OpenLibraryService().richDescription(
                existing: existing, isbn: isbn, title: book.title, authors: book.authors)
            return (text ?? "", source)
        }
        return (existing, book.descriptionSource)
    }

    /// Chooses the longest non-empty source text (ties keep earlier entries),
    /// so a thin catalog one-liner never starves out a fuller Google/Wikipedia
    /// entry. Pure so the selection policy is unit-testable.
    static func longestNonEmpty(_ candidates: [(text: String, source: String?)]) -> (text: String, source: String?)? {
        let usable = candidates.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return usable.max { a, b in
            a.text.count < b.text.count
        }
    }

    /// The rewrite request. `raw` may be empty — the prompt must then tell the
    /// model to refuse rather than fabricate.
    static func prompt(raw: String) -> AIPrompt {
        let hasSource = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return AIPrompt(
            system: """
            You are a careful, factual book editor. Rewrite the provided source description into a clear, \
            accurate 2–4 sentence description for a personal library. Use ONLY the facts that appear in the \
            source, plus general knowledge you are certain of (such as the author's well-established field). \
            NEVER invent specific facts: do not fabricate people, places, plot points, awards, dates, or \
            biographical details, and never write as though you read the book itself. Avoid flowery, poetic, \
            or filler prose. If the source text is missing (shown as none), do not fabricate a description — \
            reply exactly: No reliable description available.
            """,
            user: hasSource ? "Source description:\n\n\(raw)" : "Source description: none (the catalog has no description for this book.)"
        )
    }

    /// Writes the rewrote description plus its provenance into the model. On the
    /// first improvement it snapshots the pre-rewrite text/source so the user
    /// can switch back (`hasImprovedDescription` gates the single use). The
    /// caller saves the context.
    static func apply(_ rewritten: String, source: String?, to book: Book) {
        if !book.hasImprovedDescription {
            book.originalDescription = book.bookDescription
            book.originalDescriptionSource = book.descriptionSource
        }
        book.bookDescription = rewritten
        book.descriptionSource = source ?? book.descriptionSource
        book.hasImprovedDescription = true
        book.updatedAt = Date()
    }

    /// Switches a previously improved description back to the version saved
    /// before the improvement, restoring its original source and re-enabling
    /// "Improve description". No-op when there's nothing to revert. The caller
    /// saves the context.
    static func revert(to book: Book) {
        guard book.hasImprovedDescription else { return }
        book.bookDescription = book.originalDescription
        book.descriptionSource = book.originalDescriptionSource
        book.originalDescription = nil
        book.originalDescriptionSource = nil
        book.hasImprovedDescription = false
        book.updatedAt = Date()
    }
}
