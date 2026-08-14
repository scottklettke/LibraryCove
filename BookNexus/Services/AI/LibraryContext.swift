import Foundation

/// Builds a deterministic library snapshot that grounds the Ask AI chat in the
/// user's actual collection.
enum AILibrarySnapshot {

    /// A plain-text digest of the library: the full title catalog plus counts,
    /// what's being read now, top rated books, and genre distribution. Capped
    /// at `AIPromptFactory.contextCap` characters (hard slice, may split
    /// words). The "All books" section is emitted first so truncation keeps the
    /// catalog and drops digest detail, never the titles.
    static func build(books: [Book], users: [User]) -> String {
        var sections: [String] = []

        sections.append("Total books in library: \(books.count)")

        // Full catalog — every title plus searchable detail (author, year,
        // genres, publisher, location, description, notes), title-sorted. This
        // is what lets the model answer "list my books", "do I have…", or any
        // title/subject search — not just the digest buckets below.
        let catalog = books
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map(catalogLine)
        if !catalog.isEmpty {
            sections.append("All books:\n" + catalog.joined(separator: "\n"))
        }

        // Reading now — up to 5.
        let reading = books
            .filter { $0.status == "reading" }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(5)
        if !reading.isEmpty {
            let lines = reading.map { "\($0.title) (\($0.authorsText))" }
            sections.append("Reading now:\n" + lines.joined(separator: "\n"))
        }

        // Top rated (rating >= 4) — up to 10.
        let top = books
            .filter { ($0.rating ?? 0) >= 4 }
            .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
            .prefix(10)
        if !top.isEmpty {
            let lines = top.map { "\($0.title) — \($0.rating ?? 0)" }
            sections.append("Top rated:\n" + lines.joined(separator: "\n"))
        }

        // Genre distribution — count desc, then localized case-insensitive alpha.
        // Counting is case-insensitive (so "Sci-Fi" and "sci-fi" merge into one
        // bucket), but the first-seen original spelling is shown for readability.
        var genreCounts: [String: Int] = [:]
        var genreLabels: [String: String] = [:]
        for book in books {
            for genre in book.genres {
                let cleaned = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let key = cleaned.lowercased()
                genreCounts[key, default: 0] += 1
                if genreLabels[key] == nil { genreLabels[key] = cleaned }
            }
        }
        if !genreCounts.isEmpty {
            let lines = genreCounts
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                }
                .map { "\(genreLabels[$0.key] ?? $0.key): \($0.value)" }
            sections.append("Genres:\n" + lines.joined(separator: "\n"))
        }

        // Recently added — newest 5 by createdAt, titles only.
        let recent = books
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(5)
        if !recent.isEmpty {
            sections.append("Recently added:\n" + recent.map(\.title).joined(separator: "\n"))
        }

        let text = sections.joined(separator: "\n\n")
        if text.count <= AIPromptFactory.contextCap {
            return text
        }
        return String(text.prefix(AIPromptFactory.contextCap))
    }

    /// One catalog row: the readable "Title (Author)" plus the fields the AI
    /// should be able to search, with long text truncated per field so the row
    /// stays bounded. Description and notes carry the AI-summarized/AI-revised
    /// text, keeping those searchable.
    private static func catalogLine(for book: Book) -> String {
        var meta: [String] = []
        if !book.genres.isEmpty {
            meta.append(book.genres.joined(separator: ", "))
        }
        if let year = book.publicationYear {
            meta.append("\(year)")
        }
        if let publisher = book.publisher, !publisher.isEmpty {
            meta.append(publisher)
        }
        if let location = book.physicalLocation, !location.isEmpty {
            meta.append(location)
        }

        var line = "\(book.title) (\(book.authorsText))"
        if !meta.isEmpty {
            line += " — " + meta.joined(separator: "; ")
        }
        if let description = book.bookDescription, !description.isEmpty {
            line += "\n  Description: " + snippet(description, limit: 200)
        }
        if let summary = book.summary, !summary.isEmpty {
            line += "\n  Summary: " + snippet(summary, limit: 200)
        }
        if let notes = book.notes, !notes.isEmpty {
            let text = notes.map(\.content).joined(separator: " | ")
            line += "\n  Notes: " + snippet(text, limit: 200)
        }
        return line
    }

    private static func snippet(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

/// Builds system/user prompts for the Ask AI chat.
enum AIPromptFactory {

    /// Maximum characters of library snapshot sent to the model. Large enough
    /// to carry every book's title plus its description/details for a typical
    /// personal library, while still bounding prompt size (a 48-book library
    /// with descriptions runs ~8–12k chars).
    static let contextCap = 20000
    /// How many prior turns are included as context with each message.
    static let transcriptWindow = 8

    /// Rough tokens-per-second estimate for the on-screen indicator: ~4
    /// characters per token (the standard heuristic). Wall time includes
    /// network + generation because the API is non-streaming, so this
    /// understates true generation speed — it's an indicator, not a benchmark.
    static func tokensPerSecond(text: String, seconds: TimeInterval) -> Double {
        guard seconds > 0, !text.isEmpty else { return 0 }
        let tokens = max(1, text.count / 4)
        return Double(tokens) / seconds
    }

    /// The system prompt: grounds the assistant in the snapshot and general
    /// book knowledge without letting it invent library membership.
    static func systemPrompt(snapshot: String) -> String {
        """
        You are BookNexus, a friendly reading companion. Use only the library \
        snapshot below plus general book knowledge. Recommend books from the \
        library or generally; when ambiguous, ask one clarifying question. \
        Ratings >=4 indicate the user liked a book. Do not invent books as if \
        they are in the library.

        'All books' below lists every book in the user's library — use it to \
        list their books or answer questions like 'do I have…' or searches on \
        title words. Answer truthfully from that list; if a book is not listed, \
        the user does not own it.

        LIBRARY SNAPSHOT
        \(snapshot)
        """
    }

    /// Builds the user message. When a `book` is provided (e.g. "about my
    /// current book"), a compact card of its facts precedes the user's text.
    static func userMessage(_ text: String, book: Book? = nil) -> String {
        var message = ""
        if let book {
            let year = book.publicationYear.map(String.init) ?? "?"
            let genres = book.genres.isEmpty ? "—" : book.genres.joined(separator: ", ")
            message += "Book: \(book.title) by \(book.authorsText) (\(year) — \(genres))\n"
            message += "Description: \(book.bookDescription ?? "none")\n\n"
        }
        message += text
        return message
    }
}
