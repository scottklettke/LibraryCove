import Foundation

/// "Improve description": reuse the catalog lookup for richer source text,
/// then AI-rewrite it into `Book.bookDescription`.
enum AIDescriptionImprovement {

    /// Fetches richer source text for a book: via `OpenLibraryService.lookup`
    /// when it has an ISBN (OpenLibrary/Google, including Wikipedia fallback),
    /// otherwise the book's existing description. Never throws — a failed or
    /// empty lookup returns empty raw text, and the caller rewrites what's
    /// available rather than erroring out.
    static func onlineText(for book: Book) async -> (raw: String, source: String?) {
        if let isbn = book.isbn, !isbn.isEmpty {
            let catalog = try? await OpenLibraryService().lookup(isbn: isbn, preferred: .openlibrary)
            if let catalog {
                return (catalog.description ?? "", catalog.descriptionSource)
            }
            return (book.bookDescription ?? "", book.descriptionSource)
        }
        return (book.bookDescription ?? "", book.descriptionSource)
    }

    /// The rewrite request. `raw` may be empty (no source text to draw on).
    static func prompt(raw: String) -> AIPrompt {
        AIPrompt(
            system: "You are a book editor. Rewrite this into a vivid 2–4 sentence description for a personal library.",
            user: raw.isEmpty ? "(no source text)" : raw
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
