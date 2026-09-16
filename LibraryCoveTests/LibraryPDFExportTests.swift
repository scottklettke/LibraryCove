import Testing
import Foundation
import SwiftData
import UIKit
import PDFKit
@testable import LibraryCove

@Suite @MainActor struct LibraryPDFExportTests {

    /// Shared in-memory container. SwiftData fatals if a second in-memory
    /// container with the same model types is created in one process, so tests
    /// share `Persistence.inMemory` and reset it with `deleteAll` first.
    private func baseContext() -> ModelContext {
        Persistence.inMemory.mainContext
    }

    private func seed(_ context: ModelContext) {
        let b1 = Book(id: "b-1", title: "Dune", authors: ["Frank Herbert"],
                      isbn: "9780441172719", publicationYear: 1965,
                      tags: ["Science Fiction"],
                      bookDescription: "A classic summary of Dune.",
                      physicalLocation: "Living room shelf", rating: 5,
                      ownerID: "u-1")
        let b2 = Book(id: "b-2", title: "Solaris", authors: ["Stanisław Lem"],
                      status: "completed")
        let b3 = Book(id: "b-3", title: "", authors: [])
        context.insert(b1)
        context.insert(b2)
        context.insert(b3)
        try? context.save()
    }

    private func makeEntries(_ context: ModelContext) async -> [BookCatalogEntry] {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        return await LibraryPDFExport.makeEntries(from: books, fetchRemoteCover: { _ in nil })
    }

    @Test func renderProducesValidPDF() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        seed(context)
        let entries = await makeEntries(context)

        let data = try #require(
            LibraryPDFExport.render(entries, title: "Library Catalog",
                                    generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(data.count > 1000)
        #expect(String(data: data.prefix(5), encoding: .ascii) == "%PDF-")
    }

    @Test func renderNeedsAtLeastOneBook() {
        #expect(LibraryPDFExport.render([], title: "Empty") == nil)
    }

    /// A rendered cover thumbnail must actually appear: rasterize page 2 of
    /// the PDF (first card page) and check the thumbnail area for the
    /// fixture's orange, guarding the aspect-fill path end to end.
    @Test func renderDrawsCoverThumbnail() throws {
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90)).image { ctx in
            UIColor(red: 0.85, green: 0.33, blue: 0.10, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        }
        let entry = BookCatalogEntry(
            id: "c", title: "Cover Book", authors: ["A"], isbn: nil,
            publicationYear: nil, tags: [], statusDisplay: "To read",
            publisher: nil, pageCount: nil, bookDescription: nil, language: nil,
            physicalLocation: nil, rating: nil, loanedTo: nil, ownerName: nil,
            acquiredDate: nil, coverData: cover.jpegData(compressionQuality: 0.9)
        )
        #expect(entry.coverData != nil)
        let data = try #require(LibraryPDFExport.render([entry], title: "T"))
        let doc = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(doc.numberOfPages >= 2)
        let page = try #require(doc.page(at: 3)) // 1 cover, 2 stats, 3 cards
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let cs = CGColorSpaceCreateDeviceRGB()
        let w = Int(box.width * scale), h = Int(box.height * scale)
        var centerSample: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var cornerSample: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var maxByte = 0
        // Single buffer-backed context: fill, draw the page, and sample
        // against memory that stays valid through the whole scope.
        var pixels = Data(count: w * h * 4)
        pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let base = raw.baseAddress!
            let bmp = CGContext(
                data: base, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            bmp.setFillColor(UIColor.white.cgColor)
            bmp.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            bmp.scaleBy(x: scale, y: scale)
            bmp.drawPDFPage(page)
            let buf = raw.bindMemory(to: UInt8.self)
            for b in buf where Int(b) > maxByte { maxByte = Int(b) }
            func pixel(_ x: CGFloat, _ y: CGFloat) -> (UInt8, UInt8, UInt8) {
                // The page is drawn y-up into a bottom-origin context while
                // the buffer's first row is the image top — the two flips
                // cancel, so UIKit top-left y maps straight to buffer row.
                let px = Int(x * scale)
                let py = Int(y * scale)
                let o = (py * w + px) * 4
                return (buf[o], buf[o + 1], buf[o + 2])
            }
            centerSample = pixel(100, 135)
            cornerSample = pixel(60, 70)
        }
        // region must not be blank paper, and the page must have rendered.
        let isOrange = { (p: (UInt8, UInt8, UInt8)) in Int(p.0) > 180 && Int(p.1) < 130 && Int(p.2) < 90 }
        #expect(maxByte > 200)
        #expect(isOrange(centerSample) || isOrange(cornerSample))
    }

    @Test func pageCountScalesWithBooks() throws {
        // Directly-constructed entries: pagination depends on how many cards
        // overflow a page, not on the tiny test library.
        func entry(_ title: String) -> BookCatalogEntry {
            BookCatalogEntry(
                id: title, title: title, authors: ["An Author"], isbn: nil,
                publicationYear: 2020, tags: [],
                statusDisplay: "To read", publisher: "Press", pageCount: 300,
                bookDescription: String(repeating: "A long description paragraph. ", count: 8),
                language: "English", physicalLocation: nil, rating: nil,
                loanedTo: nil, ownerName: nil, acquiredDate: nil, coverData: nil
            )
        }
        let small = [entry("Book A")]
        let many = (1...12).map { entry("Book \($0)") }

        let smallPDF = try #require(LibraryPDFExport.render(small, title: "T"))
        let manyPDF = try #require(LibraryPDFExport.render(many, title: "T"))
        let smallDoc = try #require(CGPDFDocument(CGDataProvider(data: smallPDF as CFData)!))
        let manyDoc = try #require(CGPDFDocument(CGDataProvider(data: manyPDF as CFData)!))
        #expect(smallDoc.numberOfPages >= 2) // cover page + one card page
        #expect(manyDoc.numberOfPages > smallDoc.numberOfPages)
    }

    // MARK: - Export options

    /// Rich entries where the description actually drives pagination (title,
    /// authors, labels, and a long blurb push the text column past the cover
    /// thumbnail floor).
    private func richEntry(_ title: String) -> BookCatalogEntry {
        BookCatalogEntry(
            id: title, title: String(repeating: title + " ", count: 6),
            authors: ["Author One", "Author Two", "Author Three"], isbn: nil,
            publicationYear: 2020, tags: ["tag-one", "tag-two", "tag-three"],
            statusDisplay: "To read",
            publisher: "Press", pageCount: 300,
            bookDescription: String(repeating: "A long description paragraph. ", count: 30),
            language: "English", physicalLocation: nil, rating: nil,
            loanedTo: nil, ownerName: nil, acquiredDate: nil, coverData: nil
        )
    }

    /// Minimal entry: no description or metadata, so the card height floors
    /// at the cover thumbnail height and pagination is fully deterministic.
    private func minimalEntry(_ title: String) -> BookCatalogEntry {
        BookCatalogEntry(
            id: title, title: title, authors: ["A"], isbn: "9780000000002",
            publicationYear: nil, tags: [], statusDisplay: "To read",
            publisher: nil, pageCount: nil, bookDescription: nil, language: nil,
            physicalLocation: nil, rating: nil, loanedTo: nil, ownerName: nil,
            acquiredDate: nil, coverData: nil
        )
    }

    @Test func listLayoutUsesFewerPagesThanCards() throws {
        let books = (1...12).map { richEntry("Book \($0)") }
        let cardsPDF = try #require(LibraryPDFExport.render(books, title: "T"))
        let listPDF = try #require(LibraryPDFExport.render(books, title: "T", options: PDFExportOptions(layout: .list)))
        let cardsDoc = try #require(CGPDFDocument(CGDataProvider(data: cardsPDF as CFData)!))
        let listDoc = try #require(CGPDFDocument(CGDataProvider(data: listPDF as CFData)!))
        #expect(listDoc.numberOfPages < cardsDoc.numberOfPages)
    }

    /// The include-description toggle must remove the blurb from the rendered
    /// card; PDFKit text extraction is the observable contract.
    @Test func descriptionToggleOmitsDescription() throws {
        func extractedText(_ options: PDFExportOptions) -> String {
            let entry = BookCatalogEntry(
                id: "d", title: "Description Book", authors: ["A"], isbn: nil,
                publicationYear: nil, tags: [], statusDisplay: "To read",
                publisher: nil, pageCount: nil,
                bookDescription: "Zebraquillmark sentence for the ink scan.",
                language: nil, physicalLocation: nil, rating: nil,
                loanedTo: nil, ownerName: nil, acquiredDate: nil, coverData: nil
            )
            let data = try! #require(
                LibraryPDFExport.render([entry], title: "T", options: options)
            )
            let doc = PDFKit.PDFDocument(data: data)!
            return doc.string ?? ""
        }
        #expect(extractedText(PDFExportOptions()).contains("Zebraquillmark"),
                "description text missing with toggle on")
        #expect(!extractedText(PDFExportOptions(includeDescription: false)).contains("Zebraquillmark"),
                "description text rendered with toggle off")
    }

    @Test func statsToggleDropsStatsPage() throws {
        let books = [minimalEntry("Solo")]
        let withStats = try #require(LibraryPDFExport.render(books, title: "T"))
        let withoutStats = try #require(LibraryPDFExport.render(
            books, title: "T", options: PDFExportOptions(includeStats: false)
        ))
        let withDoc = try #require(CGPDFDocument(CGDataProvider(data: withStats as CFData)!))
        let withoutDoc = try #require(CGPDFDocument(CGDataProvider(data: withoutStats as CFData)!))
        // Default: cover + stats + cards. Stats off: cover + cards only.
        #expect(withDoc.numberOfPages == 3)
        #expect(withoutDoc.numberOfPages == 2)
    }

    @Test func coverSizeAffectsPageCount() throws {
        let books = (1...12).map { minimalEntry("Book \($0)") }
        let small = try #require(LibraryPDFExport.render(
            books, title: "T", options: PDFExportOptions(coverSize: .small)
        ))
        let large = try #require(LibraryPDFExport.render(
            books, title: "T", options: PDFExportOptions(coverSize: .large)
        ))
        let smallDoc = try #require(CGPDFDocument(CGDataProvider(data: small as CFData)!))
        let largeDoc = try #require(CGPDFDocument(CGDataProvider(data: large as CFData)!))
        #expect(largeDoc.numberOfPages > smallDoc.numberOfPages)
    }
    /// Facts line gating: with location and rating toggled off, neither the
    /// location string nor the star row may appear anywhere in the extracted
    /// text (status stays, so the line itself is still there).
    @Test func locationAndRatingTogglesOmitFacts() throws {
        let entry = BookCatalogEntry(
            id: "f", title: "Facts Book", authors: ["A"], isbn: nil,
            publicationYear: nil, tags: [], statusDisplay: "To read",
            publisher: nil, pageCount: nil, bookDescription: nil, language: nil,
            physicalLocation: "Attic crate seven", rating: 4, loanedTo: nil,
            ownerName: nil, acquiredDate: nil, coverData: nil
        )
        let withFacts = PDFKit.PDFDocument(
            data: try #require(LibraryPDFExport.render([entry], title: "T"))
        )!.string ?? ""
        #expect(withFacts.contains("Attic crate seven"), "location missing with toggles on")
        #expect(withFacts.contains("★★★★"), "rating missing with toggles on")

        let withoutFacts = PDFKit.PDFDocument(
            data: try #require(LibraryPDFExport.render(
                [entry], title: "T",
                options: PDFExportOptions(includeLocation: false, includeRating: false)
            ))
        )!.string ?? ""
        #expect(!withoutFacts.contains("Attic crate seven"), "location rendered with toggle off")
        #expect(!withoutFacts.contains("★"), "rating rendered with toggle off")
        #expect(withoutFacts.contains("To read"), "status must survive the toggles")
        // Same gating must hold in the list layout's meta line.
        let listWithoutFacts = PDFKit.PDFDocument(
            data: try #require(LibraryPDFExport.render(
                [entry], title: "T",
                options: PDFExportOptions(
                    layout: .list, includeLocation: false, includeRating: false
                )
            ))
        )!.string ?? ""
        #expect(!listWithoutFacts.contains("Attic crate seven"), "location rendered in list with toggle off")
        #expect(!listWithoutFacts.contains("★"), "rating rendered in list with toggle off")
        let listWithFacts = PDFKit.PDFDocument(
            data: try #require(LibraryPDFExport.render(
                [entry], title: "T",
                options: PDFExportOptions(layout: .list)
            ))
        )!.string ?? ""
        #expect(listWithFacts.contains("Attic crate seven"), "location missing in list with toggle on")
        #expect(listWithFacts.contains("★★★★"), "rating missing in list with toggle on")
    }
    /// The include-ISBN toggle controls the footer ISBN line; PDFKit text
    /// extraction is the observable contract.

    /// The catalog is ordered alphabetically by author, then by title within
    /// the same author, regardless of input order.
    @Test func renderSortsByAuthorThenTitle() throws {
        func named(_ title: String, _ authors: [String]) -> BookCatalogEntry {
            BookCatalogEntry(
                id: title, title: title, authors: authors, isbn: nil,
                publicationYear: nil, tags: [], statusDisplay: "To read",
                publisher: nil, pageCount: nil, bookDescription: nil, language: nil,
                physicalLocation: nil, rating: nil, loanedTo: nil, ownerName: nil,
                acquiredDate: nil, coverData: nil
            )
        }
        let books = [
            named("Aardvark", ["Zane Author"]),
            named("Beta", ["Ada Author"]),
            named("Alpha", ["Ada Author"]),
        ]
        let data = try #require(LibraryPDFExport.render(books, title: "T"))
        let text = PDFKit.PDFDocument(data: data)!.string ?? ""
        let alpha = try #require(text.range(of: "Alpha"))
        let beta = try #require(text.range(of: "Beta"))
        let aardvark = try #require(text.range(of: "Aardvark"))
        // Ada Author "Alpha" < Ada Author "Beta" < Zane Author "Aardvark"
        #expect(alpha.lowerBound < beta.lowerBound, "same-author titles out of order")
        #expect(beta.lowerBound < aardvark.lowerBound, "authors out of order")
    }
    @Test func isbnToggleOmitsISBNFooter() throws {
        func extractedText(_ options: PDFExportOptions) -> String {
            let data = try! #require(
                LibraryPDFExport.render([minimalEntry("Solo")], title: "T", options: options)
            )
            let doc = PDFKit.PDFDocument(data: data)!
            return doc.string ?? ""
        }
        #expect(extractedText(PDFExportOptions()).contains("ISBN 9780000000002"),
                "ISBN footer missing with toggle on")
        #expect(!extractedText(PDFExportOptions(includeISBN: false)).contains("9780000000002"),
                "ISBN footer rendered with toggle off")
    }

    @Test func entriesResolveAllFieldsAndStatus() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        seed(context)
        let entries = await makeEntries(context)

        #expect(entries.count == 3)
        let dune = try #require(entries.first { $0.id == "b-1" })
        #expect(dune.title == "Dune")
        #expect(dune.authors == ["Frank Herbert"])
        #expect(dune.isbn == "9780441172719")
        #expect(dune.publicationYear == 1965)
        #expect(dune.tags == ["Science Fiction"])
        #expect(dune.statusDisplay == BookStatus.toRead.displayName)
        #expect(dune.physicalLocation == "Living room shelf")
        #expect(dune.rating == 5)
        #expect(dune.ownerName == nil)
        #expect(dune.coverData == nil)

        let untitled = try #require(entries.first { $0.id == "b-3" })
        #expect(untitled.title.isEmpty)
    }

    /// The filters note prints on the cover page when provided and is absent
    /// otherwise.
    @Test func filtersNoteAppearsOnCoverWhenProvided() throws {
        let entry = minimalEntry("Solo")
        let plain = try #require(LibraryPDFExport.render([entry], title: "T"))
        let noted = try #require(LibraryPDFExport.render(
            [entry], title: "T", filtersNote: "search “dune”"
        ))
        let plainText = PDFKit.PDFDocument(data: plain)!.string ?? ""
        let notedText = PDFKit.PDFDocument(data: noted)!.string ?? ""
        #expect(!plainText.contains("Filtered by"), "filters note printed with no filters")
        #expect(notedText.contains("Filtered by search “dune”"), "filters note missing from cover")
    }

    /// Direct coverage of the note builder's branches: nothing active → nil,
    /// selection prefix, quoted search, and 4+ author compaction.
    @Test func exportFiltersNoteBuildsExpectedStrings() {
        // Nothing active: whole library, no note.
        #expect(LibraryView.exportFiltersNote(
            isSelecting: false, searchText: "   ", filteredAuthors: [], filteredTags: []
        ) == nil)
        // Selection mode prefixes the note.
        #expect(LibraryView.exportFiltersNote(
            isSelecting: true, searchText: "", filteredAuthors: [], filteredTags: []
        ) == "selected books")
        // Search text is trimmed and quoted.
        #expect(LibraryView.exportFiltersNote(
            isSelecting: false, searchText: "  dune  ", filteredAuthors: [], filteredTags: []
        ) == "search “dune”")
        // 1-3 authors are listed alphabetically; 4+ collapse to a count.
        #expect(LibraryView.exportFiltersNote(
            isSelecting: false, searchText: "",
            filteredAuthors: ["Zane, Alice"], filteredTags: []
        ) == "author Zane, Alice")
        #expect(LibraryView.exportFiltersNote(
            isSelecting: false, searchText: "",
            filteredAuthors: ["W", "X", "Y", "Z"], filteredTags: []
        ) == "4 authors")
    }


    @Test func entriesFetchRemoteCoversOncePerDistinctURL() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        let coverData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let b1 = Book(id: "b-1", title: "A", coverImageURL: "https://example.com/c.jpg")
        let b2 = Book(id: "b-2", title: "B", coverImageURL: "https://example.com/c.jpg")
        let b3 = Book(id: "b-3", title: "C", coverImageURL: "https://example.com/other.jpg")
        context.insert(b1)
        context.insert(b2)
        context.insert(b3)
        try? context.save()

        actor Counter {
            var count = 0
            func bump() -> Int { count += 1; return count }
        }
        let counter = Counter()
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let entries = await LibraryPDFExport.makeEntries(from: books) { _ in
            await counter.bump()
            return coverData
        }
        #expect(entries.filter { $0.coverData == coverData }.count == 3)
        #expect(await counter.count == 2) // two distinct URLs, fetched once each
    }

    @Test func entriesFallBackToLocalCoverStore() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        let bookID = "b-local"
        // Minimal JPEG markers; CoverImageStore hands back the stored bytes.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let b1 = Book(id: bookID, title: "Local cover book", coverImageURL: "covers/\(bookID).jpg")
        context.insert(b1)
        try? context.save()
        // deleteAll (called by other tests on the shared container) purges
        // stored cover files, so write the cover after it.
        #expect(CoverImageStore.save(jpeg, forBookID: bookID))
        defer { CoverImageStore.delete(forBookID: bookID) }

        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let entries = await LibraryPDFExport.makeEntries(from: books, fetchRemoteCover: { _ in nil })
        let entry = try #require(entries.first)
        #expect(entry.coverData == jpeg)
    }

    /// Dumps a rendered catalog to Documents so the host toolchain can turn
    /// pages into PNGs and inspect the design (convention from
    /// `LibraryDataServiceTests.exportWritesStandardZipToDocuments`).
    @Test func exportWritesCatalogPDFToDocuments() async throws {
        let context = baseContext()
        LibraryDataService.deleteAll(context: context)
        seed(context)
        let dune = try #require((try context.fetch(FetchDescriptor<Book>())).first { $0.id == "b-1" })
        dune.coverImageURL = "covers/b-1.jpg"
        try? context.save()
        // Attach a generated cover to Dune so the dumped sample exercises the
        // real aspect-fill thumbnail path, not just placeholders.
        // Encode via ImageIO: jpegData(compressionQuality:) can silently
        // return nil (saving empty bytes), which degrades to placeholders.
        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90)).image { ctx in
            UIColor(red: 0.85, green: 0.33, blue: 0.10, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
            UIColor(white: 1, alpha: 0.9).setFill()
            ctx.fill(CGRect(x: 6, y: 12, width: 48, height: 4))
            ctx.fill(CGRect(x: 6, y: 20, width: 33, height: 4))
        }
        let cg = try #require(bitmap.cgImage)
        let coverURL = CoverImageStore.fileURL(forBookID: "b-1")
        let dest = try #require(CGImageDestinationCreateWithURL(coverURL as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        defer { CoverImageStore.delete(forBookID: "b-1") }
        let saved = try #require(CoverImageStore.localData(forCover: "covers/b-1.jpg"))
        #expect(UIImage(data: saved) != nil)

        let entries = await makeEntries(context)
        // The dump must exercise the real thumbnail path: if the local cover
        // failed to resolve the sample silently degrades to placeholders.
        #expect(entries.first { $0.id == "b-1" }?.coverData != nil)
        let data = try #require(LibraryPDFExport.render(entries, title: "Library Catalog"))
        let docs = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let url = docs.appendingPathComponent("catalog-check.pdf")
        do {
            try data.write(to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
        } catch {
            Issue.record("could not write catalog pdf: \(error)")
        }
    }
}
