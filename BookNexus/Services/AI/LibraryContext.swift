import Foundation

/// Builds a deterministic library snapshot that grounds the Ask AI chat in the
/// user's actual collection.
enum AILibrarySnapshot {

    /// A plain-text digest of the library, sized to fit the model's context
    /// (`AIPromptFactory.contextCap`): the full title catalog first (every
    /// title+author always included), then as much searchable detail
    /// (summary/description/notes) as the budget allows split fairly across
    /// books, then the compact digest buckets. When detail is cut, an explicit
    /// note is appended so the model hedges instead of a confident "not found".
    static func build(books: [Book], users: [User]) -> String {
        let capacity = AIPromptFactory.contextCap
        // Reserve room for the truncation note up front — it fires whenever
        // per-book detail has to be cut, and the total must never exceed cap.
        let contentBudget = max(1, capacity - truncationNote.count)

        let header = "Total books in library: \(books.count)"

        // Compact digest buckets (status/ratings/genres/recency signal).
        var digests: [String] = []

        let reading = books
            .filter { $0.status == "reading" }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(5)
        if !reading.isEmpty {
            digests.append("Reading now:\n" + reading.map { "\($0.title) (\($0.authorsText))" }.joined(separator: "\n"))
        }

        let top = books
            .filter { ($0.rating ?? 0) >= 4 }
            .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
            .prefix(10)
        if !top.isEmpty {
            digests.append("Top rated:\n" + top.map { "\($0.title) — \($0.rating ?? 0)" }.joined(separator: "\n"))
        }

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
            digests.append("Genres:\n" + lines.joined(separator: "\n"))
        }

        let recent = books
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(5)
        if !recent.isEmpty {
            digests.append("Recently added:\n" + recent.map(\.title).joined(separator: "\n"))
        }

        let digestText = digests.joined(separator: "\n\n")

        // Catalog: every book gets its full title line; the remaining budget is
        // split evenly across books for detail (summary first — it's the text
        // users most often ask to search — then description, then notes).
        let sortedBooks = books.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let baseLines = sortedBooks.map(titleLine)
        let titlesCost = baseLines.reduce(0) { $0 + $1.count + 2 }
        let overhead = header.count + "All books:".count + digestText.count + 12
        let detailBudget = max(0, contentBudget - titlesCost - overhead)
        let perBook = sortedBooks.isEmpty ? 0 : detailBudget / sortedBooks.count

        var didTruncate = false
        let catalogLines = zip(sortedBooks, baseLines).map { book, base -> String in
            let detail = detailSuffix(for: book)
            guard !detail.isEmpty else { return base }
            if perBook <= 0 {
                didTruncate = true
                return base
            }
            if detail.count <= perBook { return base + detail }
            didTruncate = true
            return base + snippet(detail, limit: perBook)
        }
        let catalogText = "All books:\n" + catalogLines.joined(separator: "\n")

        var text = [header, catalogText]
        if !digestText.isEmpty { text.append(digestText) }
        let joined = text.joined(separator: "\n\n")
        let body = joined.count <= contentBudget ? joined : String(joined.prefix(contentBudget))

        return didTruncate ? body + truncationNote : body
    }

    /// The message appended whenever detail was cut, so the model says it
    /// can't confirm rather than reporting a confident false "not found".
    private static let truncationNote = "\n\n[The catalog above is truncated — some book details (including summaries) were cut to fit the model's context window. If you can't find the exact text, say so rather than assuming it's absent.]"

    /// The readable "Title (Author)" plus compact metadata (year, genres,
    /// publisher, location) — always included for every book.
    private static func titleLine(for book: Book) -> String {
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
        return line
    }

    /// The searchable body of a book row: summary first (most-asked text),
    /// then description, then notes. Truncated as a whole against the per-book
    /// budget, never field-by-field.
    private static func detailSuffix(for book: Book) -> String {
        var parts: [String] = []
        if let summary = book.summary, !summary.isEmpty {
            parts.append("Summary: " + summary)
        }
        if let description = book.bookDescription, !description.isEmpty {
            parts.append("Description: " + description)
        }
        if let notes = book.notes, !notes.isEmpty {
            parts.append("Notes: " + notes.map(\.content).joined(separator: " | "))
        }
        guard !parts.isEmpty else { return "" }
        return "\n  " + parts.joined(separator: "\n  ")
    }

    private static func snippet(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

/// Builds system/user prompts for the Ask AI chat.
enum AIPromptFactory {

    /// Snapshot char budget = ~50% of the configured context window (~4
    /// chars/token). Scales with `AIConfig.maxContextTokens` so it fits the
    /// model instead of overflowing it.
    static var contextCap: Int {
        max(2000, Int(Double(AIConfig.maxContextTokens) * 2.0))
    }

    /// Char budget for prior turns in a request (~30% of the context window).
    static var transcriptBudget: Int {
        max(1200, Int(Double(AIConfig.maxContextTokens) * 1.2))
    }

    /// How many prior turns are included as context with each message.
    static let transcriptWindow = 8

    /// Returns the most recent `maxTurns` turns that fit `budget` chars,
    /// always keeping the newest turn. Order is chronological.
    static func transcript(for turns: [AITurn], budget: Int, maxTurns: Int = transcriptWindow) -> [AITurn] {
        var kept: [AITurn] = []
        var used = 0
        for turn in turns.reversed() {
            let cost = turn.text.count + 12 // role/label piped into the prompt
            if used + cost > budget && !kept.isEmpty { break }
            kept.append(turn)
            used += cost
            if kept.count >= maxTurns { break }
        }
        return kept.reversed()
    }

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
        list their books or to search words in their titles, authors, \
        descriptions, summaries, and notes (e.g. 'do I have…'). Answer \
        truthfully from that list; if a book is not listed, the user does not \
        own it. If the snapshot is truncated, say so when you can't confirm, \
        rather than inventing a match.

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
