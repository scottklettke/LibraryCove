import Testing
import Foundation
import SwiftData
@testable import LibraryCove

@Suite @MainActor
struct FictionClassifierTests {

    private func makeBook(_ id: String, _ title: String, _ tags: [String], kind: String = "") -> Book {
        Book(id: id, title: title, authors: ["Someone"], publicationYear: 1999, tags: tags, kind: kind)
    }

    // MARK: - Parsing

    @Test func parseProposalsIsTolerantAndNormalizes() throws {
        let data = try #require(Data("""
        [{"bookID":"b1","kind":"fiction"},
         {"bookID":"b2","kind":"Non-fiction"},
         {"bookID":""},
         {"bookID":"b3","kind":" meh "}]
        """.utf8))
        let parsed = try FictionClassifier.parseProposals(from: data)
        #expect(parsed == [
            BookKindProposal(bookID: "b1", kind: "fiction"),
            BookKindProposal(bookID: "b2", kind: "non-fiction"),
            BookKindProposal(bookID: "b3", kind: nil), // unknown kind → no signal
        ])
    }

    @Test func parseProposalsRecoversFromTruncatedArray() throws {
        let data = try #require(Data(#"[{"bookID":"b1","kind":"fiction"},{"bookID":"b2","kind"}]"#.utf8))
        let parsed = try FictionClassifier.parseProposals(from: data)
        #expect(parsed == [BookKindProposal(bookID: "b1", kind: "fiction")])
    }

    // MARK: - Matching / apply

    @Test func matchingNeverOverwritesUserSetKind() {
        let books = [
            makeBook("a", "Fantasy One", ["Fantasy"], kind: ""),
            makeBook("b", "History Work", ["History"], kind: "non-fiction"), // user-set
            makeBook("c", "Untagged", []),
        ]
        let proposals = [
            BookKindProposal(bookID: "a", kind: "fiction"),
            BookKindProposal(bookID: "b", kind: "fiction"), // should be ignored
            BookKindProposal(bookID: "c", kind: "non-fiction"),
            BookKindProposal(bookID: "missing", kind: "fiction"), // no book
        ]
        let matched = FictionClassifier.matching(proposals, to: books)
        let byID = Dictionary(uniqueKeysWithValues: matched.map { ($0.book.id, $0.kind) })
        #expect(byID["a"] == "fiction")
        #expect(byID["c"] == "non-fiction")
        #expect(byID["missing"] == nil)
        // A proposal for an already-labeled book is dropped — never re-proposed.
        #expect(matched.contains { $0.book.id == "b" } == false)
        #expect(books.first { $0.id == "b" }?.kind == "non-fiction")
    }

    @Test func applyWritesKindsAndCountsChanges() throws {
        let context = try #require(Persistence.inMemory.mainContext)
        let a = makeBook("a", "Fantasy One", ["Fantasy"])
        let b = makeBook("b", "Kept Label", [], kind: "non-fiction")
        context.insert(a)
        context.insert(b)
        try context.save()

        let changed = FictionClassifier.apply(
            [BookKindProposal(bookID: "a", kind: "fiction"),
             BookKindProposal(bookID: "b", kind: "fiction")], // ignored: user-set
            to: [a, b], context: context)
        #expect(changed == 1)
        #expect(a.kind == "fiction")
        #expect(b.kind == "non-fiction")
    }
}

@Suite @MainActor
struct BookMasteringTests {

    private func makeBook(_ id: String, _ isbn: String?, createdAt: Double) -> Book {
        let book = Book(id: id, title: "T", authors: [], isbn: isbn, createdAt: Date(timeIntervalSince1970: createdAt))
        return book
    }

    @Test func mastersKeepsOldestPerISBNAndPassesISBNlessBooks() {
        let books = [
            makeBook("a", "978-0-441-17271-9", createdAt: 3000), // oldest → master
            makeBook("b", "9780441172719", createdAt: 1000),
            makeBook("c", "9780441172719", createdAt: 2000),
            makeBook("d", nil, createdAt: 5000), // no ISBN → always shown
        ]
        let masters = BookMastering.masters(of: books)
        // Oldest (by createdAt) of the group is the master; the ISBN-less book passes through.
        #expect(Set(masters.map(\.id)) == ["b", "d"])
    }

    @Test func copyCountsGroupByNormalizedISBN() {
        let books = [
            makeBook("a", "978-0-441-17271-9", createdAt: 1000),
            makeBook("b", "9780441172719", createdAt: 2000),
            makeBook("c", nil, createdAt: 3000),
        ]
        let counts = BookMastering.copyCounts(byISBN: books)
        #expect(counts["9780441172719"] == 2)
        #expect(counts.count == 1)
    }

    @Test func otherCopiesUseNormalizedISBNAndFallbackToTitle() {
        let books = [
            makeBook("a", "978-0-441-17271-9", createdAt: 1000),
            makeBook("b", "9780441172719", createdAt: 2000),
            makeBook("c", "9780061120084", createdAt: 3000),
        ]
        #expect(Set(BookMastering.otherCopies(of: books[0], in: books).map(\.id)) == ["b"])
        #expect(BookMastering.otherCopies(of: books[2], in: books).isEmpty)

        // No ISBN → title fallback (same title, different ids).
        let t1 = Book(id: "t1", title: "Shared Title")
        let t2 = Book(id: "t2", title: " Shared Title ")
        #expect(Set(BookMastering.otherCopies(of: t1, in: [t1, t2]).map(\.id)) == ["t2"])
    }
}

@Suite
struct ShelfStoreTests {
    @Test func addDeduplicatesCaseInsensitivelyAndPersists() {
        let store = ShelfStore()
        let before = store.shelves
        defer {
            for value in ["Home", "Travel"] where before.contains(value) == false {
                store.remove(value)
            }
        }
        let canonical = store.add("Home")
        #expect(canonical == "Home")
        // Re-adding with different case returns the original spelling.
        #expect(store.add("home") == "Home")
        #expect(store.shelves.filter { $0.caseInsensitiveCompare("Home") == .orderedSame }.count == 1)
        #expect(store.add("   ") == "")

        // A fresh instance reads the persisted shelf list.
        let reloaded = ShelfStore()
        #expect(reloaded.shelves.contains { $0.caseInsensitiveCompare("Home") == .orderedSame })
    }
}

@Suite @MainActor
struct BookDateRepairTests {

    private func makeBook(_ id: String, createdAt: Date, updatedAt: Date) -> Book {
        let book = Book(id: id, title: "T", createdAt: createdAt, updatedAt: updatedAt)
        return book
    }

    @Test func newBookDefaultsToCurrentDate() {
        // The "date added" bug: the old default was the 2001-01-01 sentinel.
        #expect(abs(Book(title: "T", authors: ["A"]).createdAt.timeIntervalSinceNow) < 60)
    }

    @Test func repairUsesLastUpdatedWhenCreatedAtIsSentinel() throws {
        let context = try #require(Persistence.inMemory.mainContext)
        let realUpdated = Date(timeIntervalSinceNow: -86_400)
        let book = makeBook("a",
                            createdAt: Date(timeIntervalSinceReferenceDate: 0),
                            updatedAt: realUpdated)
        context.insert(book)

        BookDateRepair.repairSentinelDates(books: [book], context: context)
        #expect(book.createdAt == realUpdated)
    }

    @Test func repairUsesNowWhenBothDatesAreSentinel() throws {
        let context = try #require(Persistence.inMemory.mainContext)
        let sentinel = Date(timeIntervalSinceReferenceDate: 0)
        let book = makeBook("b", createdAt: sentinel, updatedAt: sentinel)
        context.insert(book)

        BookDateRepair.repairSentinelDates(books: [book], context: context)
        #expect(abs(book.createdAt.timeIntervalSinceNow) < 60)
        #expect(BookDateRepair.isSentinel(book.createdAt) == false)
    }

    @Test func repairLeavesRealDatesUntouched() throws {
        let context = try #require(Persistence.inMemory.mainContext)
        let real = Date(timeIntervalSinceNow: -3600)
        let book = makeBook("c", createdAt: real, updatedAt: real)
        context.insert(book)

        BookDateRepair.repairSentinelDates(books: [book], context: context)
        #expect(book.createdAt == real)
        #expect(book.updatedAt == real)
    }
}
