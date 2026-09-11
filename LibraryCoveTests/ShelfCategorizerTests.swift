import Testing
import Foundation
@testable import LibraryCove

@Suite
struct ShelfCategorizerTests {

    private func makeBook(_ title: String, _ tags: [String], kind: String = "") -> Book {
        Book(title: title, authors: ["Someone"], publicationYear: 2000, tags: tags, kind: kind)
    }

    // MARK: - Parsing

    @Test func parseKeepsValidMappingsAndDropsJunk() throws {
        let data = try #require(Data("""
        [{"tag":"sci-fi","categories":["Science Fiction & Fantasy"],"kind":"fiction"},
         {"tag":" "},
         {"tag":"history","categories":["History","History"],"kind":"Non-fiction"},
         {"tag":"SCI-FI","categories":["Science Fiction & Fantasy","", "SciFi"]}]
        """.utf8))
        let mappings = try ShelfCategorizer.parseMappings(from: data)
        // Empty tag dropped; same tag (case-insensitive) deduped keeping first;
        // duplicate category within history collapsed.
        #expect(mappings.count == 2)
        #expect(mappings[0].tag == "sci-fi")
        #expect(mappings[0].categories == ["Science Fiction & Fantasy"])
        #expect(mappings[0].kind == "fiction")
        #expect(mappings[1].tag == "history")
        #expect(mappings[1].categories == ["History"])
        #expect(mappings[1].kind == "non-fiction") // normalized from "Non-fiction"
    }

    @Test func parseRejectsJunkKinds() throws {
        let data = try #require(Data(#"[{"tag":"misc","categories":["Books"],"kind":"whatever"}]"#.utf8))
        let mappings = try ShelfCategorizer.parseMappings(from: data)
        #expect(mappings.first?.kind == nil)
    }

    @Test func parseRejectsMappingWithNoUsableCategories() throws {
        let data = try #require(Data(#"[{"tag":"misc","categories":[" ",""]}]"#.utf8))
        let mappings = try ShelfCategorizer.parseMappings(from: data)
        #expect(mappings.isEmpty)
    }

    @Test func parseAcceptsSingleStringCategory() throws {
        let data = try #require(Data(#"[{"tag":"history","categories":"History"}]"#.utf8))
        let mappings = try ShelfCategorizer.parseMappings(from: data)
        #expect(mappings == [GenreTagMapping(tag: "history", categories: ["History"])])
    }

    @Test func parseRecoversFromTruncatedJSON() throws {
        // Model output cut off mid-element: the complete leading row survives.
        let data = try #require(Data(#"[{"tag":"sci-fi","categories":["Fiction"]},{"tag":"history","categ"}]"#.utf8))
        let mappings = try ShelfCategorizer.parseMappings(from: data)
        #expect(mappings == [GenreTagMapping(tag: "sci-fi", categories: ["Fiction"])])
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

    // MARK: - Flat shelf building

    @Test func sectionsMapEveryMatchingShelfAndPreserveOrder() {
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
        let sections = try! #require(ShelfCategorizer.shelfSections(books: [a, b, c], plan: plan))
        #expect(sections.map(\.shelf) == ["History", "Non-fiction", "Science Fiction"])
        let history = sections.first { $0.shelf == "History" }
        #expect(history?.books.map(\.title) == ["B", "C"])
        let scifi = sections.first { $0.shelf == "Science Fiction" }
        #expect(scifi?.books.map(\.title) == ["A", "C"])
    }

    @Test func unmappedBooksLandInSingleOtherLast() {
        let plan = ShelfCategoryPlan(
            mappings: [
                GenreTagMapping(tag: "Fiction", categories: ["Fiction"]),
                GenreTagMapping(tag: "Junk", categories: ["Other"]), // model-emitted Other
            ],
            fingerprint: "",
            createdAt: Date())
        let a = makeBook("A", ["Fiction"])
        let b = makeBook("B", ["Mystery"])     // no mapping
        let c = makeBook("C", [])              // no tags
        let d = makeBook("D", ["Junk"])        // mapped only to model "Other"
        let sections = try! #require(ShelfCategorizer.shelfSections(books: [a, b, c, d], plan: plan))
        #expect(sections.map(\.shelf) == ["Fiction", "Other"])
        // Exactly ONE Other, holding every unmapped book.
        #expect(sections.last?.books.map(\.title) == ["B", "C", "D"])
    }

    @Test func noUsablePlanReturnsNil() {
        let books = [makeBook("A", ["Fiction"])]
        #expect(ShelfCategorizer.shelfSections(books: books, plan: nil) == nil)
        #expect(ShelfCategorizer.shelfSections(books: books,
                                               plan: ShelfCategoryPlan(mappings: [], fingerprint: "", createdAt: Date())) == nil)
    }

    // MARK: - Two-tier organization (Fiction / Non-fiction → shelves)

    @Test func twoTierPartitionsByKindAndShelf() {
        let plan = ShelfCategoryPlan(
            mappings: [
                GenreTagMapping(tag: "Sci-Fi", categories: ["Science Fiction"], kind: "fiction"),
                GenreTagMapping(tag: "Gardening", categories: ["Animals"], kind: "non-fiction"),
            ],
            fingerprint: "", createdAt: Date())
        let scifi = makeBook("Dune", ["Sci-Fi"], kind: "fiction")
        let garden = makeBook("Growing", ["Gardening"], kind: "non-fiction")
        let species = makeBook("Fauna", ["Sci-Fi", "Gardening"], kind: "fiction")
        let tiers = try! #require(ShelfCategorizer.twoTierSections(books: [scifi, garden, species], plan: plan))
        #expect(tiers.map(\.top) == ["Fiction", "Non-fiction"])
        // A book lands in the top group matching ITS stored kind; its shelves
        // live under that one group. A shelf may appear under more than one top
        // group when books of different kinds share it.
        let fiction = tiers.first { $0.top == "Fiction" }
        #expect(fiction?.shelves.map(\.shelf) == ["Animals", "Science Fiction"]) // alphabetical
        #expect(fiction?.shelves.first { $0.shelf == "Science Fiction" }?.books.map(\.title) == ["Dune", "Fauna"])
        #expect(fiction?.shelves.first { $0.shelf == "Animals" }?.books.map(\.title) == ["Fauna"])
        let nonfiction = tiers.first { $0.top == "Non-fiction" }
        #expect(nonfiction?.shelves.map(\.shelf) == ["Animals"])
        // multi-membership: the fiction "species" book is FICTION-grouped, so it
        // is not on the Non-fiction Animals shelf.
        #expect(nonfiction?.shelves.first?.books.map(\.title) == ["Growing"])
    }

    /// Advisory-driven regression: books with an unset kind MUST land in
    /// Uncategorized — never a non-existent "Not set" group, never dropped.
    @Test func twoTierPlaceNotSetKindBooksInUncategorized() {
        let plan = ShelfCategoryPlan(
            mappings: [GenreTagMapping(tag: "Fantasy", categories: ["Fantasy"], kind: "fiction")],
            fingerprint: "", createdAt: Date())
        // kind omitted (defaults to "") — a migrated/pre-existing book.
        let book = Book(title: "Chronicles", authors: ["S."], publicationYear: 1990, tags: ["Fantasy"])
        let tiers = try! #require(ShelfCategorizer.twoTierSections(books: [book], plan: plan))
        let tops = tiers.map(\.top)
        #expect(tops == ["Uncategorized"])
        let uncat = tiers.first { $0.top == "Uncategorized" }
        #expect(uncat?.shelves.first?.shelf == "Fantasy")
        #expect(uncat?.shelves.first?.books.map(\.title) == ["Chronicles"])
    }

    @Test func twoTierKeepsUnmappedBooksInOtherWithinTheirKindGroup() {
        let plan = ShelfCategoryPlan(
            mappings: [GenreTagMapping(tag: "Fantasy", categories: ["Fantasy"], kind: "fiction")],
            fingerprint: "", createdAt: Date())
        let mapped = makeBook("A", ["Fantasy"], kind: "fiction")
        let unmapped = makeBook("B", ["Odds"], kind: "fiction")
        let tiers = try! #require(ShelfCategorizer.twoTierSections(books: [mapped, unmapped], plan: plan))
        let fiction = tiers.first { $0.top == "Fiction" }
        #expect(fiction?.shelves.map(\.shelf) == ["Fantasy", "Other"])
        #expect(fiction?.shelves.last?.books.map(\.title) == ["B"])
    }

    // MARK: - Fiction/non-fiction proposal

    @Test func proposedKindUsesClearTagMajority() {
        let plan = ShelfCategoryPlan(
            mappings: [
                GenreTagMapping(tag: "Fantasy", categories: ["Fantasy"], kind: "fiction"),
                GenreTagMapping(tag: "Sci-Fi", categories: ["Science Fiction"], kind: "fiction"),
            ],
            fingerprint: "", createdAt: Date())
        #expect(ShelfCategorizer.proposedKind(for: makeBook("A", ["Fantasy", "Sci-Fi"]), plan: plan) == .fiction)
    }

    @Test func proposedKindNilWhenSplitOrNoKind() {
        let plan = ShelfCategoryPlan(
            mappings: [
                GenreTagMapping(tag: "Fantasy", categories: ["Fantasy"], kind: "fiction"),
                GenreTagMapping(tag: "Gardening", categories: ["Gardening"], kind: "non-fiction"),
            ],
            fingerprint: "", createdAt: Date())
        // Tie → no clear majority → leave uncategorized rather than guess.
        #expect(ShelfCategorizer.proposedKind(for: makeBook("A", ["Fantasy", "Gardening"]), plan: plan) == nil)
        let noKind = ShelfCategoryPlan(
            mappings: [GenreTagMapping(tag: "Fantasy", categories: ["Fantasy"])],
            fingerprint: "", createdAt: Date())
        #expect(ShelfCategorizer.proposedKind(for: makeBook("B", ["Fantasy"]), plan: noKind) == nil)
    }

    // MARK: - Snapshot

    @Test func snapshotCountsNormalizedTags() {
        let books = [makeBook("A", [" Sci-Fi "]), makeBook("B", ["sci-fi", "History"])]
        let snap = ShelfCategorizer.snapshot(from: books)
        #expect(snap.contains("sci-fi: 2"))
        #expect(snap.contains("history: 1"))
    }
}
