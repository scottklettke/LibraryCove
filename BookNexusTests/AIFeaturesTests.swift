import Testing
import Foundation
import SwiftData
@testable import BookNexus

/// Unit tests for the AI assistant features: conversation transcript,
/// library snapshot, genre cleanup, and description improvement.
@Suite @MainActor struct AIFeaturesTests {

    // MARK: - ConversationMemory

    @Test func transcriptWindowReturnsLastTurnsInOrder() throws {
        let (url, dir) = try tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let memory = LocalTranscriptMemory(storageURL: url)
        memory.append(AITurn(role: .user, text: "one", date: Date(timeIntervalSince1970: 1)))
        memory.append(AITurn(role: .assistant, text: "two", date: Date(timeIntervalSince1970: 2)))
        memory.append(AITurn(role: .user, text: "three", date: Date(timeIntervalSince1970: 3)))

        let window = memory.window(limit: 2)
        #expect(window.map(\.text) == ["two", "three"])
    }

    @Test func transcriptPersistsAcrossInstances() throws {
        let (url, dir) = try tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let memory = LocalTranscriptMemory(storageURL: url)
        memory.append(AITurn(role: .user, text: "one", date: Date(timeIntervalSince1970: 1)))
        memory.append(AITurn(role: .assistant, text: "two", date: Date(timeIntervalSince1970: 2)))

        // A fresh instance reads the same persisted turns from disk.
        let reloaded = LocalTranscriptMemory(storageURL: url)
        #expect(reloaded.load().map(\.text) == ["one", "two"])
        #expect(reloaded.load().map(\.role) == [AIRole.user, .assistant])
    }

    @Test func transcriptPrunesOldestBeyondCap() throws {
        let (url, dir) = try tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let memory = LocalTranscriptMemory(storageURL: url)
        for i in 0..<(LocalTranscriptMemory.maxStoredTurns + 5) {
            memory.append(AITurn(role: .user, text: "turn \(i)", date: Date(timeIntervalSince1970: TimeInterval(i))))
        }
        let loaded = memory.load()
        #expect(loaded.count == LocalTranscriptMemory.maxStoredTurns)
        #expect(loaded.first?.text == "turn 5")
        #expect(loaded.last?.text == "turn 104")
    }

    @Test func clearRemovesPersistedTranscript() throws {
        let (url, dir) = try tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let memory = LocalTranscriptMemory(storageURL: url)
        memory.append(AITurn(role: .user, text: "one", date: Date(timeIntervalSince1970: 1)))
        memory.clear()

        #expect(memory.load().isEmpty)
        let reloaded = LocalTranscriptMemory(storageURL: url)
        #expect(reloaded.load().isEmpty)
    }

    @Test func missingOrCorruptFileLoadsEmpty() throws {
        let (url, dir) = try tempURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Never written: missing file reads as empty.
        #expect(LocalTranscriptMemory(storageURL: url).load().isEmpty)

        // Corrupt file reads as empty too.
        try Data("not json".utf8).write(to: url)
        #expect(LocalTranscriptMemory(storageURL: url).load().isEmpty)
    }

    // MARK: - Library snapshot

    @Test func snapshotIncludesReadingTopRatedGenresAndRecent() throws {
        let book1 = Book(
            title: "Dune", authors: ["Frank Herbert"],
            genres: ["Sci-Fi", "Sci-Fi", "Science Fiction"],
            status: "reading", rating: 5,
            createdAt: Date(timeIntervalSince1970: 3000)
        )
        let book2 = Book(
            title: "Solaris", authors: ["Stanislaw Lem"],
            genres: [],
            rating: 4, createdAt: Date(timeIntervalSince1970: 2000)
        )
        let book3 = Book(
            title: "Little House", authors: ["Laura Ingalls Wilder"],
            genres: ["Kids"], rating: 3,
            createdAt: Date(timeIntervalSince1970: 1000)
        )

        let snapshot = AILibrarySnapshot.build(books: [book1, book2, book3], users: [])

        #expect(snapshot.contains("Total books in library: 3"))
        // Reading now.
        #expect(snapshot.contains("Reading now:"))
        #expect(snapshot.contains("Dune (Frank Herbert)"))
        // Top rated (rating >= 4): both titles with ratings.
        #expect(snapshot.contains("Solaris — 4"))
        // Genres with case-insensitive counting and deterministic ordering.
        #expect(snapshot.contains("Sci-Fi: 2"))
        #expect(snapshot.contains("Science Fiction: 1"))
        let sciFiIndex = snapshot.range(of: "Sci-Fi: 2")?.lowerBound
        let sfIndex = snapshot.range(of: "Science Fiction: 1")?.lowerBound
        #expect(sciFiIndex != nil)
        #expect(sfIndex != nil)
        if let sciFiIndex, let sfIndex {
            #expect(sciFiIndex < sfIndex)
        }
    }

    @Test func snapshotIncludesFullCatalogBeyondDigestBuckets() {
        // A book that is NOT being read, NOT top-rated (rating < 4), and NOT in
        // the "recently added" window (oldest of 6 recent books) must still
        // appear in the snapshot via the full catalog — otherwise the model can
        // neither list it nor match its title words.
        let books = (0..<6).map { i in
            Book(
                title: String(format: "Book %02d", i),
                authors: ["Author \(i)"],
                status: "to-read",
                rating: 2,
                createdAt: Date(timeIntervalSince1970: Double(1000 + i))
            )
        }
        let snapshot = AILibrarySnapshot.build(books: books, users: [])

        #expect(snapshot.contains("All books:"))
        for i in 0..<6 {
            #expect(snapshot.contains("Book \(String(format: "%02d", i)) (Author \(i))"),
                    "catalog missing book \(i)")
        }
        // Book 00 is the oldest → excluded from "Recently added" (newest 5);
        // its presence proves the catalog is the carrier.
        #expect(!snapshot.contains("Recently added:\nBook 00"))
    }

    @Test func snapshotShipsFullSummaryBeyondOldTruncation() {
        // A keyword placed past the old 200-char per-field cap must reach the
        // model — regression for "AI couldn't find a word in my summary".
        let summary = String(repeating: "m", count: 250) + "needle-of-proof"
        let book = Book(title: "Dune", summary: summary)
        let snapshot = AILibrarySnapshot.build(books: [book], users: [])

        #expect(snapshot.contains("needle-of-proof"))
    }

    @Test func snapshotTruncationIsLoudNotSilent() {
        // A catalog too big for the cap never hangs or silently drops content:
        // it stays within budget and tells the model the text is incomplete.
        let pad = String(repeating: "z", count: 2000)
        let books = (0..<40).map { _ in
            Book(title: "Book", authors: ["A"], genres: ["G"],
                 bookDescription: pad, summary: pad)
        }
        let snapshot = AILibrarySnapshot.build(books: books, users: [])

        #expect(snapshot.count <= AIPromptFactory.contextCap)
        #expect(snapshot.contains("truncated"))
    }

    @Test func contextBudgetScalesWithConfiguredWindow() {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }

        let small = AIPromptFactory.contextCap
        AIConfig.maxContextTokens = 32768
        #expect(AIPromptFactory.contextCap > small)
        #expect(AIPromptFactory.transcriptBudget > 1200)
        AIConfig.maxContextTokens = AIConfig.defaultMaxContextTokens
        #expect(AIPromptFactory.contextCap == small)
    }

    @Test func transcriptTrimKeepsNewestAndFitsBudget() {
        let turns = (0..<6).map { i in
            AITurn(role: .user, text: String(repeating: "a", count: 120), date: Date(timeIntervalSince1970: Double(i)))
        }
        // 120-char turns; a 300-char budget fits the newest 2 (240), not 3 (360).
        let trimmed = AIPromptFactory.transcript(for: turns, budget: 300)

        #expect(trimmed.last?.text == turns.last?.text) // newest always kept
        let total = trimmed.reduce(0) { $0 + $1.text.count }
        #expect(total <= 300)
        #expect(trimmed.count == 2)
        #expect(trimmed.map(\.date) == Array(turns.suffix(2).map(\.date))) // chronological
    }

    @Test func transcriptKeepsNewestEvenWhenOverBudget() {
        let turns = [AITurn(role: .user, text: "x", date: Date(timeIntervalSince1970: 0)),
                     AITurn(role: .assistant, text: String(repeating: "y", count: 5000), date: Date(timeIntervalSince1970: 1))]
        // Budget 100: the newest (5000 chars) must still be returned.
        let trimmed = AIPromptFactory.transcript(for: turns, budget: 100)
        #expect(trimmed == [turns.last!])
    }

    @Test func snapshotCapsAtContextLimit() {
        let books = (0..<10).map { i in
            Book(title: "Book number \(i) with a very long padded title ".padding(toLength: 160, withPad: "x", startingAt: 0),
                 authors: ["An Author"],
                 genres: ["Genre \(i)"],
                 rating: 5,
                 createdAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let snapshot = AILibrarySnapshot.build(books: books, users: [])
        #expect(snapshot.count <= AIPromptFactory.contextCap)
    }

    @Test func userMessageIncludesBookCard() {
        let book = Book(title: "Dune", authors: ["Frank Herbert"], publicationYear: 1965,
                        genres: ["Science Fiction"], bookDescription: "A desert epic.")
        let message = AIPromptFactory.userMessage("Is this my favorite?", book: book)
        #expect(message.contains("Dune by Frank Herbert (1965 — Science Fiction)"))
        #expect(message.contains("Description: A desert epic."))
        #expect(message.contains("Is this my favorite?"))
    }

    // MARK: - Genre cleanup

    @Test func parsesGenreSuggestionsWithRemovals() throws {
        let json = #"[{"from":"Sci-Fi","to":"Science Fiction"},{"from":"none","to":null}]"#
        let suggestions = try #require(try GenreCleanupService.parseSuggestions(from: Data(json.utf8)))
        #expect(suggestions.count == 2)
        #expect(suggestions[0].from == "Sci-Fi")
        #expect(suggestions[0].to == "Science Fiction")
        #expect(suggestions[1].from == "none")
        #expect(suggestions[1].to == nil)
    }

    @Test func parseDropsEmptyFromAndEmptyTo() throws {
        let json = #"[{"from":"","to":"x"},{"from":"  ","to":null},{"from":"scifi","to":""},{"from":"SF","to":"Science Fiction"},{"from":"SF","to":"Some Fiction"}]"#
        let suggestions = try #require(try GenreCleanupService.parseSuggestions(from: Data(json.utf8)))
        #expect(suggestions.count == 2)
        // "SF" is deduped to the first occurrence; empty `to` collapsed to nil.
        #expect(suggestions[0].from == "scifi")
        #expect(suggestions[0].to == nil)
        #expect(suggestions[1].from == "SF")
        #expect(suggestions[1].to == "Science Fiction")
    }

    @Test func applyRewritesMergesAndRemovesGenres() throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        defer { LibraryDataService.deleteAll(context: context) }

        let book = Book(title: "Gateway", genres: ["Sci-Fi", "none", "Drama"])
        context.insert(book)
        try? context.save()

        let suggestions = try #require(try GenreCleanupService.parseSuggestions(
            from: Data(#"[{"from":"Sci-Fi","to":"Science Fiction"},{"from":"none","to":null}]"#.utf8)
        ))
        let changed = GenreCleanupService.apply(suggestions, to: [book], context: context)

        #expect(changed == 1)
        #expect(book.genres == ["Science Fiction", "Drama"])
    }

    @Test func applyIsCaseInsensitiveAndDedupes() throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        defer { LibraryDataService.deleteAll(context: context) }

        // Mixed case and near-duplicates collapse into one canonical genre.
        let book = Book(title: "Foundation", genres: ["sci-fi", "Sci-Fi", "Sci Fi"])
        context.insert(book)
        try? context.save()

        let suggestions = [GenreSuggestion(from: "sci-fi", to: "Science Fiction"),
                           GenreSuggestion(from: "Sci Fi", to: "Science Fiction")]
        let changed = GenreCleanupService.apply(suggestions, to: [book], context: context)

        #expect(changed == 1)
        #expect(book.genres == ["Science Fiction"])
    }

    // MARK: - Description improvement

    @Test func showTokenRateDefaultsOffAndPersists() {
        AIConfig.resetForTesting()
        #expect(AIConfig.showTokenRate == false)
        AIConfig.showTokenRate = true
        #expect(AIConfig.showTokenRate == true)
        AIConfig.showTokenRate = false
        #expect(AIConfig.showTokenRate == false)
    }

    @Test func tokensPerSecondEstimate() {
        // 400 characters ≈ 100 tokens (4 chars each) over 2s → 50 tok/s.
        #expect(AIPromptFactory.tokensPerSecond(text: String(repeating: "a", count: 400), seconds: 2) == 50)
        // Zero/negative elapsed never divides by zero.
        #expect(AIPromptFactory.tokensPerSecond(text: "hello", seconds: 0) == 0)
        // Empty output yields no rate.
        #expect(AIPromptFactory.tokensPerSecond(text: "", seconds: 1) == 0)
        // At least one token counts, so short replies still rate something.
        #expect(AIPromptFactory.tokensPerSecond(text: "hi", seconds: 0.5) == 2)
    }

    @Test func descriptionPromptIsDeterministic() {
        let prompt = AIDescriptionImprovement.prompt(raw: "Some raw source text")
        #expect(prompt.system?.contains("vivid") == true)
        #expect(prompt.user == "Some raw source text")

        let emptyPrompt = AIDescriptionImprovement.prompt(raw: "")
        #expect(emptyPrompt.user == "(no source text)")
    }

    @Test func descriptionApplySetsFieldsAndBumpsUpdatedAt() throws {
        // Deterministic, so this works without an AI engine.
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        defer { LibraryDataService.deleteAll(context: context) }

        let book = Book(title: "Solaris", bookDescription: "old text", descriptionSource: "openlibrary")
        context.insert(book)
        try? context.save()
        let before = book.updatedAt

        AIDescriptionImprovement.apply("A vivid new description", source: "googlebooks", to: book)

        #expect(book.bookDescription == "A vivid new description")
        #expect(book.descriptionSource == "googlebooks")
        #expect(book.updatedAt > before)
    }

    @Test func descriptionApplyKeepsExistingSourceWhenNoneProvided() throws {
        let book = Book(title: "Dune", bookDescription: "old", descriptionSource: "wikipedia")

        AIDescriptionImprovement.apply("Rewritten", source: nil, to: book)

        #expect(book.bookDescription == "Rewritten")
        #expect(book.descriptionSource == "wikipedia")
    }

    @Test func snapshotCatalogCarriesDescriptionAndDetail() {
        let book = Book(
            title: "Dune", authors: ["Frank Herbert"],
            publicationYear: 1965, genres: ["Science Fiction"],
            bookDescription: "A deep-space epic about power, faith, and spice on Arrakis.",
            summary: "In two sentences: Dune follows House Atreides on Arrakis."
        )
        let snapshot = AILibrarySnapshot.build(books: [book], users: [])

        #expect(snapshot.contains("All books:"))
        #expect(snapshot.contains("Dune (Frank Herbert) — Science Fiction; 1965"))
        #expect(snapshot.contains("Description: A deep-space epic about power, faith, and spice on Arrakis."))
        #expect(snapshot.contains("Summary: In two sentences: Dune follows House Atreides on Arrakis."))
    }

    @Test func descriptionApplyStoresOriginalOnlyOnce() {
        let book = Book(title: "Dune", bookDescription: "Original text", descriptionSource: "openlibrary")

        AIDescriptionImprovement.apply("First revision", source: "openlibrary", to: book)
        #expect(book.bookDescription == "First revision")
        #expect(book.originalDescription == "Original text")
        #expect(book.hasImprovedDescription == true)

        // A second call (guarded in the UI, but defensive here) must not
        // clobber the saved original.
        AIDescriptionImprovement.apply("Second revision", source: "googlebooks", to: book)
        #expect(book.originalDescription == "Original text")
        #expect(book.originalDescriptionSource == "openlibrary")
        #expect(book.bookDescription == "Second revision")
    }

    @Test func revertRestoresOriginalAndClearsMarker() {
        let book = Book(title: "Dune", bookDescription: "Original text", descriptionSource: "wikipedia")

        AIDescriptionImprovement.apply("Revised text", source: "openlibrary", to: book)
        AIDescriptionImprovement.revert(to: book)

        #expect(book.bookDescription == "Original text")
        #expect(book.descriptionSource == "wikipedia")
        #expect(book.originalDescription == nil)
        #expect(book.originalDescriptionSource == nil)
        #expect(book.hasImprovedDescription == false)
    }

    @Test func revertWithoutImprovementIsNoOp() {
        let book = Book(title: "Dune", bookDescription: "Original text", descriptionSource: "openlibrary")
        AIDescriptionImprovement.revert(to: book)
        #expect(book.bookDescription == "Original text")
        #expect(book.hasImprovedDescription == false)
    }

    // MARK: - Retrieval-first snapshot (overflow fix)

    @Test func targetedQueryDropsMassiveCatalogToFitTinyContext() {
        // Regression for the original overflow: 48 books each with a 2k-char
        // description + summary used to produce a ~190k-char snapshot that
        // burst the on-device 4096-token budget on the FIRST question. With
        // retrieval-first context, a simple question ships only the title
        // index + the matched book's detail + the compact digest.
        let pad = String(repeating: "z", count: 2000)
        var books = (0..<48).map { i in
            Book(title: String(format: "Book %02d", i), authors: ["Author \(i)"],
                 bookDescription: pad, summary: pad)
        }
        books.append(Book(title: "Dune", authors: ["Frank Herbert"],
                          bookDescription: "Paul Atreides journeys to Arrakis, the desert planet of spice.",
                          summary: "A desert epic about power, faith, and spice."))

        let snapshot = AILibrarySnapshot.build(books: books, users: [], query: "Do I have Dune?")

        #expect(snapshot.count <= AIPromptFactory.contextCap)
        // The matched book's searchable detail reaches the model intact…
        #expect(snapshot.contains("Description: Paul Atreides journeys to Arrakis, the desert planet of spice."))
        // …every other title is still indexed (the model can confirm/refute)…
        #expect(snapshot.contains("Book 47 (Author 47)"))
        // …and nothing had to be cut, so no truncation note fired.
        #expect(!snapshot.contains("truncated"))
    }

    @Test func retrievalTargetsNamedBookAndKeepsSnapshotSlim() {
        let dune = Book(title: "Dune", authors: ["Frank Herbert"], genres: ["Science Fiction"],
                        bookDescription: "Paul Atreides journeys to Arrakis, the desert planet of spice.",
                        summary: "A desert epic about power, faith, and spice.")
        let solaris = Book(title: "Solaris", authors: ["Stanislaw Lem"], genres: ["Science Fiction"],
                           bookDescription: "A psychologist studies an ocean that mirrors human minds.")

        let snapshot = AILibrarySnapshot.build(books: [dune, solaris], users: [], query: "Tell me about Dune")

        // The full catalog index is always present (the model can list every
        // book)…
        #expect(snapshot.contains("Dune (Frank Herbert) — Science Fiction"))
        #expect(snapshot.contains("Solaris (Stanislaw Lem) — Science Fiction"))
        // …but only the matched book carries its searchable detail, so the
        // whole library's descriptions never enter the model's context.
        #expect(snapshot.contains("Description: Paul Atreides journeys to Arrakis, the desert planet of spice."))
        #expect(!snapshot.contains("ocean that mirrors human minds"))
        #expect(snapshot.count <= AIPromptFactory.contextCap)
    }

    @Test func retrievalKeywordFindsSummaryMention() {
        let walrus = Book(title: "The Voyage", summary: "A sailor befriends a walrus in the Arctic winter.")
        let other = Book(title: "Antipodes", summary: "Ornithology on a remote island.")

        let snapshot = AILibrarySnapshot.build(books: [walrus, other], users: [], query: "which book mentions a walrus")

        #expect(snapshot.contains("Summary: A sailor befriends a walrus in the Arctic winter."))
        #expect(!snapshot.contains("remote island"))
    }

    @Test func retrievalMatchesAuthorSurname() {
        let lem = Book(title: "Solaris", authors: ["Stanislaw Lem"], summary: "A sentient ocean. ")
        let herbert = Book(title: "Dune", authors: ["Frank Herbert"], summary: "Desert planet politics. ")

        let snapshot = AILibrarySnapshot.build(books: [lem, herbert], users: [], query: "books by Lem")

        #expect(snapshot.contains("Summary: A sentient ocean."))
        #expect(!snapshot.contains("Desert planet politics."))
    }

    @Test func abstractQueryKeepsOnlyIndexAndDigest() {
        let books = (0..<6).map { i in
            Book(title: "Book \(i)", authors: ["A \(i)"],
                 bookDescription: String(repeating: "detail \(i) ", count: 40),
                 createdAt: Date(timeIntervalSince1970: Double(1000 + i)))
        }
        // An open-ended question has no retrieval match — no book's details
        // ride along, so the request is tiny and cannot overflow even a 4k
        // window, while the full title index still grounds the answer.
        let snapshot = AILibrarySnapshot.build(books: books, users: [], query: "What should I read next?")

        #expect(snapshot.contains("Total books in library: 6"))
        for i in 0..<6 { #expect(snapshot.contains("Book \(i) (A \(i))")) }
        #expect(!snapshot.contains("Description: detail"))
        #expect(!snapshot.contains("truncated"))
        #expect(snapshot.count < 4500)
    }

    @Test func retrievalRanksNamedAboveKeywordAndCapsAtTen() {
        let books = (0..<15).map { i in
            Book(title: "Book \(i)", authors: ["Author \(i)"],
                 bookDescription: "A story set on the \(i == 0 ? "moon" : "sea") during a voyage.")
        }
        // "moon" is a whole title word here → named tier (3.0), outranking the
        // keyword-tier description match (2.0).
        let named = Book(title: "The Moon Is a Harsh Mistress",
                         authors: ["Robert Heinlein"],
                         bookDescription: "A lunar colony fights for independence.")

        let hits = LibraryRetriever.retrieve(query: "books about the moon", books: books + [named])
        #expect(hits.count <= 10) // hard cap
        #expect(hits.first?.book.title == "The Moon Is a Harsh Mistress")
        let ranked = hits.map(\.score)
        #expect(ranked == ranked.sorted(by: >)) // strictly descending here
    }

    // The semantic tier uses on-device NaturalLanguage sentence embeddings and
    // is calibrated against measured similarity (paraphrase ≈0.34 vs control
    // ≈0.22/0.07, floor 0.28) — a thin contract on Apple's model, so CI
    // without the embedding asset skips it via `semanticSearchAvailable`.
    @Test func retrievalSemanticRecallsParaphrasedContent() {
        let garden = Book(title: "Gardening for Beginners", authors: ["Anna Green"],
                          bookDescription: "How to grow tomatoes and roses.")
        let odyssey = Book(title: "The Odyssey", authors: ["Homer"],
                           bookDescription: "An ancient Greek hero's long journey home after war.")
        let physics = Book(title: "A Brief History of Time", authors: ["Stephen Hawking"],
                           bookDescription: "Physics and cosmology for everyone.")

        guard LibraryRetriever.semanticSearchAvailable else { return }
        // The question shares NO literal word with "grow tomatoes and roses",
        // so only the semantic tier can surface it.
        let hits = LibraryRetriever.retrieve(
            query: "A practical manual for cultivating vegetables and flowering plants at home",
            books: [garden, odyssey, physics]
        )
        let titles = hits.map(\.book.title)
        #expect(titles.contains("Gardening for Beginners"))
        #expect(!titles.contains("The Odyssey"))
        #expect(!titles.contains("A Brief History of Time"))
    }

    @Test func effectiveContextTokensUsesConfiguredWindow() async {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AIConfig.selectedEngine = .openAI
        AIConfig.openAIBaseURL = "https://api.example.com/v1"
        AIConfig.openAIAPIKey = "test-key"
        AIConfig.maxContextTokens = 8192

        let limit = await AIService.shared.effectiveContextTokens()
        #expect(limit == 8192)
    }

    // MARK: - AI connection logs

    @Test func logStoreAppendsAndPersists() {
        AILogStore.clear()
        defer { AILogStore.clear() }

        AILogStore.append(AILogEntry(engine: .openAI, kind: .attempt, detail: "Endpoint: x"))
        AILogStore.append(AILogEntry(engine: .openAI, kind: .success, detail: "Received 5 characters.", latencyMs: 412))

        let entries = AILogStore.entries()
        #expect(entries.count == 2)
        #expect(entries.map(\.kind) == [.attempt, .success])
        #expect(entries[1].latencyMs == 412)
        #expect(entries[1].engine == .openAI)
        #expect(entries[0].date <= entries[1].date)
    }

    @Test func logStoreCapsAtMaxEntries() {
        AILogStore.clear()
        defer { AILogStore.clear() }

        for i in 0..<(AILogStore.maxEntries + 5) {
            AILogStore.append(AILogEntry(engine: .openAI, kind: .attempt, detail: "entry \(i)"))
        }
        let entries = AILogStore.entries()
        #expect(entries.count == AILogStore.maxEntries)
        #expect(entries.first?.detail == "entry 5")
        #expect(entries.last?.detail == "entry 104")
    }

    @Test func logStoreClearRemovesEntries() {
        AILogStore.clear()
        defer { AILogStore.clear() }

        AILogStore.append(AILogEntry(engine: .openAI, kind: .error, detail: "boom"))
        #expect(!AILogStore.entries().isEmpty)
        AILogStore.clear()
        #expect(AILogStore.entries().isEmpty)
    }

    // MARK: - Helpers

    private func baseContext() -> ModelContext {
        Persistence.inMemory.mainContext
    }

    private func tempURL() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIFeaturesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("ai-conversation.json"), dir)
    }
}
