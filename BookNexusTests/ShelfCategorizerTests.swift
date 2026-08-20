import Testing
import Foundation
@testable import BookNexus

@Suite
struct ShelfCategorizerTests {

    private func makeBook(_ title: String, _ genres: [String]) -> Book {
        Book(title: title, authors: ["Someone"], publicationYear: 2000, genres: genres)
    }

    // MARK: - Parsing

    @Test func parseKeepsValidMappingsAndDropsJunk() throws {
        let data = try #require(Data("""
        [{"tag":"sci-fi","categories":["Science Fiction & Fantasy"]},
         {"tag":" "},
         {"tag":"history","categories":["History","History"]},
         {"tag":"SCI-FI","categories":["Science Fiction & Fantasy","", "SciFi"]}]
        """.utf8))
        let mappings = try ShelfCategorizer.parseMappings(from: data)
        // Empty tag dropped; same tag (case-insensitive) deduped keeping first;
        // duplicate category within history collapsed.
        #expect(mappings.count == 2)
        #expect(mappings[0].tag == "sci-fi")
        #expect(mappings[0].categories == ["Science Fiction & Fantasy"])
        #expect(mappings[1].tag == "history")
        #expect(mappings[1].categories == ["History"])
    }

    @Test func parseRejectsMappingWithNoUsableCategories() throws {
        let data = try #require(Data(#"[{"tag":"misc","categories":[" ",""]}]"#.utf8))
        let mappings = try ShelfCategorizer.parseMappings(from: data)
        #expect(mappings.isEmpty)
    }

    // MARK: - Fingerprint

    @Test func fingerprintIsDeterministicAndOrderInsensitive() {
        #expect(ShelfCategorizer.fingerprint(of: ["Sci-Fi", "History"]) ==
                ShelfCategorizer.fingerprint(of: ["History", "sci-fi"]))
        #expect(ShelfCategorizer.fingerprint(of: ["Sci-Fi"]) !=
                ShelfCategorizer.fingerprint(of: ["Sci-Fi", "History"]),
                "adding a tag must invalidate a plan")
    }

    @Test func planValidityTracksTheTagSet() {
        let plan = ShelfCategoryPlan(mappings: [],
                                     fingerprint: ShelfCategorizer.fingerprint(of: ["Sci-Fi"]),
                                     createdAt: Date())
        #expect(ShelfCategorizer.isValid(plan, forTags: ["sci-fi", " Sci-Fi "]) == true)
        #expect(ShelfCategorizer.isValid(plan, forTags: ["Sci-Fi", "History"]) == false,
                "a grown tag set must mark the plan stale so it gets re-run")
    }

    // MARK: - Shelf building

    @Test func sectionsMapEveryMatchingCategoryAndPreserveOrder() {
        let plan = ShelfCategoryPlan(
            mappings: [
                GenreTagMapping(tag: "Sci-Fi", categories: ["Science Fiction"]),
                GenreTagMapping(tag: "History", categories: ["History", "Non-fiction"]),
            ],
            fingerprint: "",
            createdAt: Date())
        let a = makeBook("A", ["Sci-Fi"])
        let b = makeBook("B", ["History"])
        let c = makeBook("C", ["Sci-Fi", "History"])
        // b and c both have "history" → both under History; c also under Sci-Fi.
        let sections = try! #require(ShelfCategorizer.shelfSections(books: [a, b, c], plan: plan))
        #expect(sections.map(\.category) == ["History", "Non-fiction", "Science Fiction"]) // alphabetical
        let history = sections.first { $0.category == "History" }
        #expect(history?.books.map(\.title) == ["B", "C"])
        let scifi = sections.first { $0.category == "Science Fiction" }
        #expect(scifi?.books.map(\.title) == ["A", "C"])
    }

    @Test func unmappedBooksLandInOtherLast() {
        let plan = ShelfCategoryPlan(
            mappings: [GenreTagMapping(tag: "Fiction", categories: ["Fiction"])],
            fingerprint: "",
            createdAt: Date())
        let a = makeBook("A", ["Fiction"])
        let b = makeBook("B", ["Mystery"])
        let c = makeBook("C", [])
        let sections = try! #require(ShelfCategorizer.shelfSections(books: [a, b, c], plan: plan))
        #expect(sections.map(\.category) == ["Fiction", "Other"])
        #expect(sections.last?.books.map(\.title) == ["B", "C"])
    }

    @Test func noUsablePlanReturnsNil() {
        let books = [makeBook("A", ["Fiction"])]
        #expect(ShelfCategorizer.shelfSections(books: books, plan: nil) == nil)
        #expect(ShelfCategorizer.shelfSections(books: books,
                                               plan: ShelfCategoryPlan(mappings: [], fingerprint: "", createdAt: Date())) == nil)
    }

    // MARK: - Snapshot

    @Test func snapshotCountsNormalizedTags() {
        let books = [makeBook("A", [" Sci-Fi "]), makeBook("B", ["sci-fi", "History"])]
        let snap = ShelfCategorizer.snapshot(from: books)
        #expect(snap.contains("sci-fi: 2"))
        #expect(snap.contains("history: 1"))
    }
}
