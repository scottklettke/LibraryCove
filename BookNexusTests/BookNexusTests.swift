import Testing
import SwiftData
@testable import BookNexus

@Suite struct BookModelTests {
    @Test func bookDefaults() throws {
        let book = Book(title: "Dune")
        #expect(book.title == "Dune")
        #expect(book.status == "to-read")
        #expect(book.syncState == "modified")
        #expect(book.authorsText == "Unknown")
    }

    @Test func statusParsing() throws {
        #expect(BookStatus(raw: "reading") == .reading)
        #expect(BookStatus(raw: "not-a-status") == nil)
    }
}

@Suite struct PersistenceTests {
    @MainActor @Test func inMemoryContainerInsertsBook() throws {
        let container = Persistence.inMemory
        let context = container.mainContext
        let book = Book(title: "Foundation")
        context.insert(book)
        try context.save()

        let fetch = FetchDescriptor<Book>()
        let books = try container.mainContext.fetch(fetch)
        #expect(books.count == 1)
        #expect(books.first?.title == "Foundation")
    }
}
