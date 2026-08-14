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
