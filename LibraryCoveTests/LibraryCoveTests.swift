import Testing
import SwiftData
import UIKit
@testable import LibraryCove

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
        // Suites share this container (LibraryDataServiceTests' note):
        // clear rows earlier suites left so the count asserts THIS
        // test's insert, not their leftovers.
        try context.delete(model: Book.self)
        let book = Book(title: "Foundation")
        context.insert(book)
        try context.save()

        let fetch = FetchDescriptor<Book>()
        let books = try container.mainContext.fetch(fetch)
        #expect(books.count == 1)
        #expect(books.first?.title == "Foundation")
    }
}

@Suite struct CoverProcessorTests {

    /// A deterministic LCG so the generated "photo" is reproducible; the
    /// same seed always produces the same image (and thus the same byte sizes).
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Builds a photo-like cover image at iPhone-camera resolution: smooth
    /// colour gradients (what most of a book jacket is) plus fine textures
    /// and edge detail, so the JPEG has realistic content to encode.
    private func makePhotoLikeImage(width: CGFloat = 4032, height: CGFloat = 3024) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Diagonal colour wash (spine highlight → jacket shade).
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor(red: 0.16, green: 0.22, blue: 0.42, alpha: 1).cgColor,
                    UIColor(red: 0.62, green: 0.30, blue: 0.18, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 1]
            )!
            ctx.cgContext.drawLinearGradient(gradient,
                                             start: .zero,
                                             end: CGPoint(x: width, y: height),
                                             options: [])
            // Fine grit so the JPEG carries real high-frequency detail.
            var rng = LCG(state: 0xC0FFEE)
            let cell: CGFloat = 64
            for y in stride(from: 0, through: height, by: cell) {
                for x in stride(from: 0, through: width, by: cell) {
                    let n = CGFloat(rng.next() % 100) / 100
                    UIColor(white: 0.5, alpha: 0.12 * n).setFill()
                    ctx.cgContext.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
            // Vertical "page edges" for crisp structural detail.
            for x in stride(from: 0, through: width, by: 260) {
                ctx.cgContext.setAlpha(0.10)
                ctx.cgContext.move(to: CGPoint(x: x, y: 0))
                ctx.cgContext.addLine(to: CGPoint(x: x, y: height))
                ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
                ctx.cgContext.strokePath()
            }
            ctx.cgContext.setAlpha(1)
        }
    }

    /// Downscaling must keep a meaningful quality ceiling while shrinking the
    /// stored payload substantially. Also logs the measured sizes so the
    /// space-savings estimate is grounded in the real encode pipeline.
    @MainActor @Test func resizeKeepsCoversCrispAndSmall() throws {
        let photo = makePhotoLikeImage()

        // True "before": the old BookFormView pipeline — UIGraphicsImageRenderer
        // default format, whose scale is the screen's (3x on iPhone), so a
        // `maxDimension: 900` point cap actually stored a 2700px JPEG.
        let oldSize = photo.size
        let oldScale = 900.0 / max(oldSize.width, oldSize.height)
        let oldNewSize = CGSize(width: oldSize.width * oldScale, height: oldSize.height * oldScale)
        let oldRenderer = UIGraphicsImageRenderer(size: oldNewSize)
        let oldResized = oldRenderer.image { _ in
            photo.draw(in: CGRect(origin: .zero, size: oldNewSize))
        }
        let oldURL = "data:image/jpeg;base64," + oldResized.jpegData(compressionQuality: 0.8)!.base64EncodedString()

        // "After": the shipped CoverImageData pipeline (current cap, scale-1).
        let newURL = try #require(CoverImageData.encode(photo))

        // Reference pixel caps for the estimate table (scale-1 renderers).
        func storedLength(pixels: CGFloat) -> Int {
            let r = CoverImageData.resize(photo, maxPixelDimension: pixels)
            return ("data:image/jpeg;base64," + r.jpegData(compressionQuality: 0.8)!.base64EncodedString()).utf8.count
        }

        let oldBytes = oldURL.utf8.count
        let newBytes = newURL.utf8.count
        let dim480 = storedLength(pixels: 480)
        let dim800 = storedLength(pixels: 800)

        print("COVER-SIZES old-900pt(2700px)-q0.8 stored=\(oldBytes)B "
              + "| new\(Int(CoverImageData.maxPixelDimension))px-q0.8 stored=\(newBytes)B "
              + "| 480px-q0.8 stored=\(dim480)B | 800px-q0.8 stored=\(dim800)B")

        // Contract: the stored URL is materially smaller than the old cap.
        #expect(newBytes < oldBytes / 2, "new cover should be <50% of the old stored size")

        // A canonical 3:2 cover photo would be upscaled from ~200→300px @3x for
        // the largest render; verify the stored 640px covers that corner case.
        let decoded = try #require(UIImage(data: Data(base64Encoded: String(newURL.drop(while: { $0 != "," }).dropFirst()))!))
        let longestEdge = max(decoded.size.width, decoded.size.height)
        #expect(longestEdge <= CoverImageData.maxPixelDimension + 1,
                "decoded cover should not exceed the pixel cap")
        let smallest = min(decoded.size.width, decoded.size.height)
        #expect(smallest >= CoverImageData.maxPixelDimension * 3 / 4,
                "aspect ratio must survive (portrait covers stay tall enough for a 100×140pt render)")
    }
}

@Suite struct CropMathTests {
    private let start = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)

    @Test func cornerDragKeepsOppositePinned() {
        let br = PhotoCropView.adjusted(start, target: .cornerBR, dx: 0.1, dy: -0.05)
        #expect(abs(br.minX - start.minX) < 0.0001)
        #expect(abs(br.minY - start.minY) < 0.0001)
        #expect(abs(br.width - 0.7) < 0.0001)   // 0.6 + 0.1
        #expect(abs(br.height - 0.55) < 0.0001) // 0.6 - 0.05

        let tl = PhotoCropView.adjusted(start, target: .cornerTL, dx: 0.05, dy: 0.1)
        #expect(abs(tl.maxX - start.maxX) < 0.0001)
        #expect(abs(tl.maxY - start.maxY) < 0.0001)
        #expect(abs(tl.width - 0.55) < 0.0001)  // 0.6 - 0.05
        #expect(abs(tl.height - 0.5) < 0.0001)  // 0.6 - 0.1
    }

    @Test func edgeDragShrinksOneSideOnly() {
        let r = PhotoCropView.adjusted(start, target: .edgeTop, dx: 0.0, dy: 0.1)
        #expect(abs(r.minX - start.minX) < 0.0001)
        #expect(abs(r.maxY - start.maxY) < 0.0001) // bottom pinned
        #expect(abs(r.height - 0.5) < 0.0001)      // 0.6 - 0.1

        let r2 = PhotoCropView.adjusted(start, target: .edgeRight, dx: -0.15, dy: 0.0)
        #expect(abs(r2.minX - start.minX) < 0.0001) // left pinned
        #expect(abs(r2.width - 0.45) < 0.0001)      // 0.6 - 0.15
        #expect(abs(r2.height - start.height) < 0.0001)
    }

    @Test func moveTranslatesWithoutResizing() {
        let r = PhotoCropView.adjusted(start, target: .move, dx: 0.1, dy: 0.05)
        #expect(abs(r.minX - 0.3) < 0.0001)
        #expect(abs(r.minY - 0.25) < 0.0001)
        #expect(abs(r.width - start.width) < 0.0001)
        #expect(abs(r.height - start.height) < 0.0001)
    }

    @Test func minSideClampPreventsCollapse() {
        // Cram the BR corner all the way toward the TL.
        let r = PhotoCropView.adjusted(start, target: .cornerBR, dx: -1, dy: -1)
        #expect(r.width >= 0.2 - 0.0001)
        #expect(r.height >= 0.2 - 0.0001)
        // Stays inside the image.
        #expect(r.minX >= 0 && r.maxX <= 1 && r.minY >= 0 && r.maxY <= 1)
    }
}

@Suite struct ISBNNormalizationTests {
    /// Canonical ISBN-10 → ISBN-13 conversion pair from the ISBN standard
    /// docs. Hardcoded so the test can't self-validate a broken algorithm.
    @Test func isbn10ConvertsTo13() {
        #expect(Book.normalizedISBN("0-306-40615-2") == "9780306406157")
        #expect(Book.normalizedISBN("0306406152") == "9780306406157")
    }

    /// ISBN-10 check digit X (e.g. several Penguin Classics) also converts.
    /// 0-8044-2957-X → 9780804429573.
    @Test func isbn10WithXCheckDigitConverts() {
        #expect(Book.normalizedISBN("0-8044-2957-X") == "9780804429573")
        #expect(Book.normalizedISBN("080442957x") == "9780804429573")
    }

    @Test func isbn13PassesThroughAndDashesAreStripped() {
        #expect(Book.normalizedISBN("978-0-441-17271-9") == "9780441172719")
        #expect(Book.normalizedISBN(" 9780441172719 ") == "9780441172719")
    }

    /// The dedupe invariant this whole fix exists for: the same book seen as
    /// ISBN-10 (typed) and ISBN-13 (scanned) must normalize to one key.
    @Test func isbn10And13FormsOfSameBookCollide() {
        #expect(Book.normalizedISBN("0306406152") == Book.normalizedISBN("9780306406157"))
    }

    @Test func garbageReturnsNil() {
        #expect(Book.normalizedISBN(nil) == nil)
        #expect(Book.normalizedISBN("") == nil)
        #expect(Book.normalizedISBN("   ") == nil)
        // 10-char shape must be digit-shaped to convert; all letters fail
        // isbn10To13's digit guard.
        #expect(Book.normalizedISBN("abcdefghij") == nil)
    }

    @Test func manualStubUsesNormalizedIsbn() {
        let stub = CatalogBook.manualStub(isbn: "0-306-40615-2")
        #expect(stub.isbn == "9780306406157")
        #expect(stub.id == "isbn-9780306406157")
    }
}

/// URLProtocol stub for the description-candidate service test. Separate
/// from AITests' MockURLProtocol (different suite, no `.serialized` coupling).
private final class CatalogStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func catalogJSON(_ body: [String: Any], request: URLRequest) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
    return (response, try! JSONSerialization.data(withJSONObject: body))
}

@Suite struct DescriptionCandidateTests {
    /// The candidate collector dedupes identical texts across sources and
    /// labels each result with its origin. ISBN lookups resolve through
    /// `search.json?q=isbn:` (the retired `/api/books` endpoint answers 404),
    /// and the record's description comes from its work record. The stub
    /// returns the SAME blurb from that work record and from Google-by-ISBN,
    /// plus a distinct Google title-search text — the picker must show two
    /// rows, with the shared blurb labelled by the union of its sources.
    @Test func candidatesDedupeIdenticalTextsAndLabelSources() async throws {
        let shared = "A publisher blurb."
        let googleTitle = "Google title blurb."
        CatalogStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            // OpenLibrary ISBN search: a titled doc → the record row. The
            // separate work-key search (no "isbn" in the query) stays key-only.
            if path.contains("/search.json") {
                if query.contains("isbn:") {
                    return catalogJSON(["docs": [["key": "/works/OL1", "title": "A Book",
                                                  "author_name": ["An Author"]]]], request: request)
                }
                return catalogJSON(["docs": [["key": "/works/OL1"]]], request: request)
            }
            if path.hasSuffix("/works/OL1.json") {
                return catalogJSON(["description": ["value": shared]], request: request)
            }
            // Wikipedia: no article → the record's description comes from the
            // OpenLibrary work record (source label "openlibrary").
            if path.contains("/w/api.php") {
                return catalogJSON(["query": ["search": []]], request: request)
            }
            // Google Books volumes API (host is not part of url.path): the
            // ISBN query repeats the shared blurb, the title query differs.
            if path.contains("/books/v1/volumes") {
                if query.contains("isbn:") {
                    return catalogJSON(["items": [["volumeInfo": ["description": shared]]]], request: request)
                }
                return catalogJSON(["items": [["volumeInfo": ["description": googleTitle]]]], request: request)
            }
            return catalogJSON([:], request: request)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStubProtocol.self]
        let service = OpenLibraryService(session: URLSession(configuration: config))

        let candidates = await service.descriptionCandidates(
            isbn: "9780306406157", title: "A Book", authors: ["An Author"],
            current: nil)

        let sources = candidates.flatMap { $0.sources.compactMap { $0 } }
        #expect(sources.contains("openlibrary"))
        #expect(sources.contains("googlebooks"))
        #expect(candidates.filter { $0.text == shared }.count == 1,
                "identical texts from the work record and Google-by-ISBN must dedupe to one row")
        #expect(candidates.count == 2)
        // The shared blurb arrives via the ISBN record (whose description
        // text Google supplied — the record row is labelled "googlebooks")
        // and the OpenLibrary work search — the label must carry the union.
        let sharedRow = try #require(candidates.first { $0.text == shared })
        #expect(sharedRow.sources.compactMap { $0 } == ["googlebooks", "openlibrary"])
        let googleRow = try #require(candidates.first { $0.text == googleTitle })
        #expect(googleRow.sources.compactMap { $0 } == ["googlebooks"])
    }

    /// The book's current text is always offered as a candidate even when no
    /// source returns anything (so the user can keep or compare it).
    @Test func currentTextIncludedEvenWhenSourcesEmpty() async {
        CatalogStubProtocol.handler = { request in
            catalogJSON([:], request: request)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStubProtocol.self]
        let service = OpenLibraryService(session: URLSession(configuration: config))

        let candidates = await service.descriptionCandidates(
            isbn: "9780306406157", title: "A Book", authors: ["An Author"],
            current: "My own description.")

        #expect(candidates.count == 1)
        #expect(candidates.first?.text == "My own description.")
        #expect(candidates.first?.sources == [nil])
    }
    /// When the current text matches a fetched description, the row dedupes
    /// to the fetched source instead of showing "Current text" + the source
    /// as two identical rows (the Wikipedia-shown-twice bug).
    @Test func currentTextDedupesIntoFetchedSource() async {
        CatalogStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/w/api.php") {
                if let query = request.url?.query, query.contains("list=search") {
                    return catalogJSON(["query": ["search": [["title": "A Book (novel)"]]]], request: request)
                }
                return catalogJSON(["query": ["pages": ["123": ["extract": "Wiki text."]]]], request: request)
            }
            return catalogJSON([:], request: request)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStubProtocol.self]
        let service = OpenLibraryService(session: URLSession(configuration: config))

        let candidates = await service.descriptionCandidates(
            isbn: nil, title: "A Book", authors: ["An Author"],
            current: "Wiki text.")

        #expect(candidates.count == 1)
        // Current text matches the Wikipedia extract: one row, labelled
        // "Current text · Wikipedia" (nil = current, so picking it preserves
        // the existing label).
        #expect(candidates.first?.sources == [nil, "wikipedia"])
    }
}

@Suite struct WebSearchEngineTests {
    /// The q parameter must survive "&"/"=" inside book titles (think
    /// "War & Peace") — URLComponents encoding, not string interpolation.
    @Test func searchURLEncodesQuerySafely() throws {
        let url = try #require(WebSearchEngine.duckduckgo.searchURL(for: "War & Peace Tolstoy"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = try #require(components.queryItems?.first { $0.name == "q" }?.value)
        #expect(q == "War & Peace Tolstoy")
    }

    /// Every engine builds a valid https search URL for an empty query too
    /// (the form can be submitted with title and authors blank).
    @Test func allEnginesBuildValidURLs() throws {
        for engine in WebSearchEngine.allCases {
            let url = try #require(engine.searchURL(for: "The Odyssey Homer"))
            #expect(url.scheme == "https")
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.contains { $0.name == "q" } == true)
        }
    }

    /// The persisted selection falls back to DuckDuckGo, not Google, per the
    /// user's "rather than defaulting to Google" requirement.
    @Test func selectionDefaultsToDuckDuckGo() {
        UserDefaults.standard.removeObject(forKey: "description.webSearchEngine")
        #expect(WebSearchEngine.selected == .duckduckgo)
        WebSearchEngine.selected = .kagi
        #expect(WebSearchEngine.selected == .kagi)
        UserDefaults.standard.removeObject(forKey: "description.webSearchEngine")
    }

    /// The shared builder both the edit form and the detail page use:
    /// title + first author + "description", on the selected engine; nil
    /// when there's no usable title to search on.
    @Test func bookDescriptionURLAppendsDescriptionWord() throws {
        UserDefaults.standard.removeObject(forKey: "description.webSearchEngine")
        defer { UserDefaults.standard.removeObject(forKey: "description.webSearchEngine") }

        let url = try #require(WebSearchEngine.bookDescriptionURL(
            title: "Dune", authors: ["Frank Herbert", "Editor Someone"]))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = try #require(components.queryItems?.first { $0.name == "q" }?.value)
        #expect(q == "Dune Frank Herbert description")
        #expect(url.host == "duckduckgo.com")

        // No (or blank) title → nothing to search; must not produce a
        // bare "description" query.
        #expect(WebSearchEngine.bookDescriptionURL(title: "", authors: ["Nobody"]) == nil)
        #expect(WebSearchEngine.bookDescriptionURL(title: "   ", authors: []) == nil)

        // Missing authors still searches on the title alone.
        #expect(WebSearchEngine.bookDescriptionURL(title: "Dune", authors: []) != nil)
    }
}

@Suite struct ISBNLookupTests {
    private func makeService() -> OpenLibraryService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStubProtocol.self]
        return OpenLibraryService(session: URLSession(configuration: config))
    }

    /// The scanned-ISBN failure the user hit: OpenLibrary retired
    /// `/api/books`, and ISBN resolution must flow through
    /// `search.json?q=isbn:` instead. The stub answers that query with a
    /// titled doc; the lookup must map it (with the scanned ISBN pinned,
    /// not the doc's arbitrary first entry) instead of returning nil.
    @Test func lookupResolvesViaSearchJSONIsbnQuery() async throws {
        CatalogStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.contains("/search.json") {
                if query.contains("isbn:") {
                    return catalogJSON(["docs": [["key": "/works/OL77",
                                                  "title": "Testament of Youth",
                                                  "author_name": ["Vera Brittain"],
                                                  "first_publish_year": 1933]]], request: request)
                }
                return catalogJSON(["docs": []], request: request)
            }
            return catalogJSON([:], request: request)
        }

        let service = makeService()
        let book = try await #require(service.lookup(isbn: "9780860688134"))
        #expect(book.title == "Testament of Youth")
        #expect(book.authors == ["Vera Brittain"])
        #expect(book.isbn == "9780860688134", "the scanned ISBN must be pinned, not the doc's first entry")
        #expect(book.olWorkKey == "/works/OL77")
        #expect(book.source == "openlibrary")
    }

    /// A malformed OpenLibrary answer (empty body / HTML error page — how
    /// `/api/books` failed) must degrade to "no record" and let Google
    /// answer, never throw the whole lookup.
    @Test func malformedOpenLibraryAnswerFallsBackToGoogle() async throws {
        CatalogStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/search.json") {
                // Raw HTML error page — not JSON at all.
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "text/html"])!
                return (response, Data("<html><body>503</body></html>".utf8))
            }
            if path.contains("/books/v1/volumes") {
                return catalogJSON(["items": [["volumeInfo": [
                    "title": "Google Title", "authors": ["G. Author"]]]]], request: request)
            }
            return catalogJSON([:], request: request)
        }

        let service = makeService()
        let book = try await #require(service.lookup(isbn: "9780000000001"))
        #expect(book.title == "Google Title")
        #expect(book.source == "googlebooks")
    }

    /// An OpenLibrary miss (numFound 0 — the ISBN isn't in the index) must
    /// likewise fall through to Google.
    @Test func emptySearchJSONFallsBackToGoogle() async throws {
        CatalogStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/search.json") {
                return catalogJSON(["numFound": 0, "docs": []], request: request)
            }
            if path.contains("/books/v1/volumes") {
                return catalogJSON(["items": [["volumeInfo": [
                    "title": "Only Google Knows", "publishedDate": "1999-05-01"]]]], request: request)
            }
            return catalogJSON([:], request: request)
        }

        let service = makeService()
        let book = try await #require(service.lookup(isbn: "9780596520873"))
        #expect(book.title == "Only Google Knows")
        #expect(book.publicationYear == 1999)
        #expect(book.source == "googlebooks")
    }
}
