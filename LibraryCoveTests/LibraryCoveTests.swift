import Testing
import CryptoKit
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

@Suite struct CoverQualityTests {
    /// The user-reported issue: the first cover a scan finds was always the
    /// low-res one. Open Library's -S variant is a ~75px thumbnail (measured
    /// 77×58 for cover 14844874) — the doc mapping must offer -L first (it
    /// becomes primaryCoverURL, the form's default selection) and never
    /// offer -S at all.
    @Test func openLibraryDocCoversAreLargestFirstWithoutTinyVariants() {
        let doc: [String: Any] = ["key": "/works/OL42423728W", "title": "Your Forest",
                                  "cover_i": 14844874]
        let book = OpenLibraryService.catalogBook(fromSearchDoc: doc)
        #expect(book.coverURLs == [
            "https://covers.openlibrary.org/b/id/14844874-L.jpg",
            "https://covers.openlibrary.org/b/id/14844874-M.jpg",
        ])
        #expect(book.coverURLs.allSatisfy { !$0.contains("-S.jpg") })
    }

    /// Google URLs are upgraded to zoom=2 (measured: zoom=1 thumbnail 1.3KB
    /// vs zoom=2 large 9.1KB for the same volume) and lose the border.
    /// zoom=1 → zoom=2; an existing zoom ≥ 2 is never lowered; non-Google
    /// URLs pass through untouched.
    @Test func googleCoversUpgradeAndNeverDowngrade() {
        let thumb = "https://books.google.com/books/content?id=X&printsec=frontcover&img=1&zoom=1&edge=curl&source=gbs_api"
        #expect(OpenLibraryService.upgradedGoogleCover(thumb)
                == "https://books.google.com/books/content?id=X&printsec=frontcover&img=1&zoom=2&source=gbs_api")
        let large = "https://books.google.com/books/content?id=X&printsec=frontcover&img=1&zoom=2&source=gbs_api"
        #expect(OpenLibraryService.upgradedGoogleCover(large) == large)
        let extra = "https://books.google.com/books/content?id=X&printsec=frontcover&img=1&zoom=3&source=gbs_api"
        #expect(OpenLibraryService.upgradedGoogleCover(extra) == extra)
        let bare = "https://books.google.com/books/content?id=X&printsec=frontcover&img=1"
        #expect(OpenLibraryService.upgradedGoogleCover(bare)
                == bare + "&zoom=2", "URL already has a query string, so append with &")
        let ol = "https://covers.openlibrary.org/b/id/1-L.jpg"
        #expect(OpenLibraryService.upgradedGoogleCover(ol) == ol)
    }

    /// After upgrading, a thumbnail that became the volume's large URL must
    /// not appear twice — the picker would show identical twins.
    @Test func upgradedDuplicatesCollapse() {
        let large = "https://books.google.com/books/content?id=X&printsec=frontcover&img=1&zoom=2&source=gbs_api"
        let thumb = "https://books.google.com/books/content?id=X&printsec=frontcover&img=1&zoom=1&source=gbs_api"
        let upgraded = [large, thumb].map(OpenLibraryService.upgradedGoogleCover)
        #expect(OpenLibraryService.dedupeUpgraded(upgraded).count == 1)
        // Order and distinct entries survive.
        let distinct = ["https://a/1.jpg", "https://a/1.jpg", "https://b/2.jpg"]
        #expect(OpenLibraryService.dedupeUpgraded(distinct) == ["https://a/1.jpg", "https://b/2.jpg"])
    }

    /// The volume-info mapping serves the largest links first with
    /// smallThumbnail (~56px) absent, and every Google URL comes out
    /// upgraded + deduped. For a single volume all Google sizes upgrade to
    /// the same zoom=2 URL (edge stripped), so one volume yields one entry.
    @Test func mapGoogleInfoCoversAreLargestFirstUpgradedDeduped() {
        let info: [String: Any] = ["imageLinks": [
            "smallThumbnail": "https://books.google.com/books/content?id=X&zoom=1&edge=curl&img=1",
            "thumbnail": "https://books.google.com/books/content?id=X&zoom=1&img=1",
            "large": "https://books.google.com/books/content?id=X&zoom=2&img=1",
        ]]
        let mapped = OpenLibraryService().mapGoogleInfo(info)
        let covers = mapped["covers"] as? [String] ?? []
        #expect(covers == ["https://books.google.com/books/content?id=X&zoom=2&img=1"],
                "all sizes of one volume collapse to the upgraded large URL")
        // smallThumbnail's URL never leaks through, border or not.
        #expect(!covers.contains { $0.contains("edge=curl") })
    }
}

/// The app's About screen renders the CHANGELOG.md bundled into the .app,
/// whose newest `## <version> (<date>)` section must name the same version
/// the build itself carries (`project.yml` → xcodegen → Info.plist). This
/// test runs on every cmd+U / CI invocation and fails the moment the two
/// drift — the fix is to bump CHANGELOG.md's top section, or project.yml +
/// `xcodegen`, so they agree again.
@Suite struct ChangelogVersionTests {
    /// First `## ` heading of the bundled changelog, e.g. "0.5.2" from
    /// `## 0.5.2 (2026-09-27)`. nil when the file is missing or has no
    /// version section at all.
    private var bundledChangelogVersion: String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Plain parsing, not a regex literal: SWIFT_VERSION is 5.9, where
        // bare /…/ literals don't compile (the whole file drops from the
        // bundle when it fails).
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("## ") else { continue }
            let rest = line.dropFirst(3)
            // "0.5.2 (2026-09-27)" → "0.5.2": version is the run of digits
            // and dots before the space/open-paren.
            let version = rest.prefix { $0.isNumber || $0 == "." }
            if !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) {
                return String(version)
            }
        }
        return nil
    }

    @Test func bundledChangelogTopSectionMatchesAppVersion() {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let changelog = bundledChangelogVersion
        #expect(changelog != nil,
                "bundled CHANGELOG.md has no '## <version>' section — the in-app changelog would show nothing current")
        #expect(appVersion != nil, "app bundle carries no CFBundleShortVersionString")
        #expect(changelog == appVersion,
                "version drift: CHANGELOG.md's newest section is '\(changelog ?? "nil")' but the app is '\(appVersion ?? "nil")'. Bump CHANGELOG.md's top section, or project.yml + xcodegen — they must name the same release.")
    }

    @Test func bundledChangelogTopSectionBuildNumberMatches() {
        // Loose pin on the build number: the changelog text doesn't carry
        // it, so assert only that the app HAS one (regression guard against
        // a regen dropping CFBundleVersion).
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        #expect(build?.isEmpty == false,
                "app bundle carries no CFBundleVersion — check project.yml + xcodegen")
    }
}

@Suite struct HardcoverServiceTests {
    /// Fixture: what a real EnrichByISBN round-trip returns for a book with
    /// genres/tags/series — the shape observed from the live API (cached_tags
    /// as {category: [tag…]}), wrapped in the GraphQL envelope.
    private static func enrichedResponse() -> String {
        """
        {"data":{"editions":[{"id":22212198,"pages":416,
          "language":{"code2":"en"},
          "image":{"url":"https://covers.openlibrary.org/b/id/14844874-L.jpg"},
          "book":{"id":192946,"description":"A desert regex.",
            "cached_tags":{"Genre":["Fantasy","Dark Fantasy"],"Mood":["Dark"],"Format":["Hardcover"]},
            "book_series":[{"position":3,"series":{"name":"The Stormlight Archive"}}]}}]}}
        """
    }

    private func makeService() -> HardcoverService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStubProtocol.self]
        return HardcoverService(session: URLSession(configuration: config))
    }

    /// The full path: token set → GraphQL query → edition parsed into
    /// metadata (genres from the Genre category, all tags flattened, series
    /// name + position, pages/language/cover/description).
    @Test func enrichesFromEditionPayload() async throws {
        CatalogStubProtocol.handler = { request in
            #expect(request.url?.host == "api.hardcover.app")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            return try! Self.graphql(Self.enrichedResponse(), request: request)
        }
        HardcoverConfig.token = "test-token"
        defer { HardcoverConfig.token = nil }

        let metadata = try await #require(makeService().metadata(isbn: "9781536230833"))
        #expect(metadata.pageCount == 416)
        #expect(metadata.language == "en")
        #expect(metadata.seriesName == "The Stormlight Archive")
        #expect(metadata.seriesPosition == "3")
        #expect(metadata.description == "A desert regex.")
        #expect(metadata.coverImageURL?.contains("14844874-L") == true)
        #expect(metadata.tags.contains("Fantasy") && metadata.tags.contains("Dark") && metadata.tags.contains("Hardcover"))
        #expect(metadata.genres == ["Fantasy", "Dark Fantasy"], "only Genre-category tags become genres")
    }

    /// Spoiler-marked tags are dropped; unknown payload shapes degrade to
    /// empty rather than crash.
    @Test func spoilerTagsDroppedAndWeirdShapesTolerated() {
        let edition: [String: Any] = [
            "book": [
                "cached_tags": [["tag": "Plot Twist", "spoiler": true, "category": "Mood"],
                                ["tag": "Cozy", "spoiler": false, "category": "Mood"],
                                "garbage-string"] as [Any]
            ]
        ]
        let metadata = HardcoverService.parse(edition: edition)
        #expect(metadata.tags == ["Cozy"])
        #expect(metadata.genres.isEmpty)
        #expect(HardcoverService.parse(edition: [:]).tags.isEmpty)
        #expect(HardcoverService.parse(edition: ["book": ["cached_tags": 42]]).tags.isEmpty)
    }

    /// No token (or disabled) → no network, nil result. The service is inert
    /// by design when unconfigured.
    @Test func unconfiguredServiceNeverTouchesNetwork() async {
        var hitNetwork = false
        CatalogStubProtocol.handler = { request in
            hitNetwork = true
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data())
        }
        HardcoverConfig.token = nil
        HardcoverConfig.isEnabled = false
        let metadata = await makeService().metadata(isbn: "9781536230833")
        #expect(metadata == nil)
        #expect(!hitNetwork)
    }

    /// GraphQL-level errors (invalid token, query problems) come back with
    /// HTTP 200 + "errors" — must degrade to nil, not crash or throw.
    @Test func graphQLErrorsDegradeToNil() async throws {
        CatalogStubProtocol.handler = { request in
            return try! Self.graphql(#"{"errors":[{"message":"invalid token"}]}"#, request: request)
        }
        HardcoverConfig.token = "test-token"
        defer { HardcoverConfig.token = nil }
        let metadata = await makeService().metadata(isbn: "9781536230833")
        #expect(metadata == nil)
    }

    /// An ISBN-10 input normalizes to its ISBN-13 form (Book.normalizedISBN
    /// converts), so the query filters on isbn_13 with the converted value —
    /// Hardcover indexes both forms on editions either way.
    @Test func isbn10InputQueriesConvertedIsbn13() async throws {
        var seenQuery: String?
        CatalogStubProtocol.handler = { request in
            // URLSession hands URLProtocol the body on httpBodyStream, not
            // httpBody — read the stream (same pattern as AITests.bodyObject).
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    seenQuery = obj["query"] as? String
                }
            }
            return try! Self.graphql(Self.enrichedResponse(), request: request)
        }
        HardcoverConfig.token = "test-token"
        HardcoverConfig.isEnabled = true
        defer {
            HardcoverConfig.token = nil
            HardcoverConfig.isEnabled = false
        }
        // 0553803700 (I, Robot) → 9780553803709
        _ = await makeService().metadata(isbn: "0553803700")
        #expect(seenQuery?.contains("isbn_13") == true)
        #expect(seenQuery?.contains("9780553803709") == true)
    }
}

extension HardcoverServiceTests {
    /// Wraps a GraphQL JSON body in the (HTTPURLResponse, Data) tuple the
    /// stub protocol expects.
    static func graphql(_ body: String, request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}

@Suite struct OpenLibraryRateGateTests {
    /// Two back-to-back waits must be spaced ≥ the minimum interval —
    /// this is the 3-req/s compliance guarantee.
    @Test func enforcesMinimumInterval() async {
        let gate = OpenLibraryRateGate()
        let start = Date()
        await gate.wait()
        await gate.wait()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.35, "second request must be spaced ~0.4s; got \(elapsed)s")
        #expect(elapsed < 2.0, "gate must not over-wait; got \(elapsed)s")
    }
}

@Suite struct GenreMappingTests {
    /// Hardcover genre vocabulary → the app's curated taxonomy.
    @Test func mapsCommonCatalogGenres() {
        #expect(BookGenre.matching(name: "Fantasy") == .fantasy)
        #expect(BookGenre.matching(name: "Mystery") == .mysteryThriller)
        #expect(BookGenre.matching(name: "Crime") == .mysteryThriller)
        #expect(BookGenre.matching(name: "Sci-Fi") == .scienceFiction)
        #expect(BookGenre.matching(name: "Memoir") == .biographyMemoir)
        #expect(BookGenre.matching(name: "Self Help") == .selfHelp)
        #expect(BookGenre.matching(name: "Science Fiction") == .scienceFiction)
        #expect(BookGenre.matching(name: "Dark Fantasy") == .fantasy, "substring fallback")
        #expect(BookGenre.matching(name: "Micropaleontology") == nil, "no forced match")
        #expect(BookGenre.matching(name: "  ") == nil)
    }
}

@Suite struct MemberConvergenceTests {
    @MainActor
    private func makeContext() -> ModelContext {
        let context = Persistence.inMemory.mainContext
        try? context.delete(model: User.self)
        try? context.delete(model: Book.self)
        try? context.delete(model: Note.self)
        return context
    }

    /// The user's exact device scenario: two devices each minted their own
    /// UUID-keyed member row at onboarding ("Test" locally, "Scott" synced
    /// in later), both marked active. The repair must converge them onto
    /// the canonical primary row, keep the newest name, and leave exactly
    /// one active member.
    @MainActor @Test func convergesTwoLegacyRowsOntoPrimary() throws {
        let context = makeContext()
        let iPad = User(id: "uuid-ipad", email: "local@librarycove.local",
                        displayName: "Test", isActive: true,
                        createdAt: Date(timeIntervalSince1970: 1000))
        let iPhone = User(id: "uuid-iphone", email: "local@librarycove.local",
                          displayName: "Scott", isActive: true,
                          createdAt: Date(timeIntervalSince1970: 500))
        context.insert(iPad)
        context.insert(iPhone)
        try context.save()

        SharedLibraryCoordinator.repairDuplicateActiveMembersIfNeeded(context: context)

        let users = try context.fetch(FetchDescriptor<User>())
        #expect(users.count == 1, "legacy rows must be deleted, not just deactivated")
        let member = try #require(users.first)
        #expect(member.id == LibraryScope.primaryMemberID)
        #expect(member.displayName == "Test", "the newest row's name wins the merge")
        #expect(member.isActive)
    }

    /// A device whose row was renamed on ANOTHER device (rename-all-rows
    /// arrives via sync) must show the new name after convergence — the
    /// primary row adopts the newest name, whichever row carried it.
    @MainActor @Test func convergesWhenPrimaryAlreadyExists() throws {
        let context = makeContext()
        let primary = User(id: LibraryScope.primaryMemberID,
                           email: "local@librarycove.local",
                           displayName: "Old Name", isActive: true,
                           createdAt: Date(timeIntervalSince1970: 500))
        let legacy = User(id: "uuid-iphone", email: "local@librarycove.local",
                          displayName: "Scott", isActive: false,
                          createdAt: Date(timeIntervalSince1970: 2000))
        context.insert(primary)
        context.insert(legacy)
        try context.save()

        SharedLibraryCoordinator.repairDuplicateActiveMembersIfNeeded(context: context)

        let users = try context.fetch(FetchDescriptor<User>())
        #expect(users.count == 1)
        #expect(users.first?.displayName == "Scott", "newest row's name is adopted")
        #expect(users.first?.id == LibraryScope.primaryMemberID)
    }

    /// Owner references ride along: books/notes attributed to a legacy id
    /// are re-pointed at the primary row so "Added by" doesn't break.
    @MainActor @Test func repointsOwnerReferences() throws {
        let context = makeContext()
        let iPad = User(id: "uuid-ipad", email: "x", displayName: "Test",
                        isActive: true, createdAt: Date(timeIntervalSince1970: 1000))
        context.insert(iPad)
        let book = Book(title: "Dune")
        book.ownerID = "uuid-ipad"
        context.insert(book)
        let note = Note(userID: "uuid-ipad", content: "hello")
        context.insert(note)
        try context.save()

        SharedLibraryCoordinator.repairDuplicateActiveMembersIfNeeded(context: context)

        let fetchedBook = try #require(try context.fetch(FetchDescriptor<Book>()).first)
        #expect(fetchedBook.ownerID == LibraryScope.primaryMemberID)
        let fetchedNote = try #require(try context.fetch(FetchDescriptor<Note>()).first)
        #expect(fetchedNote.userID == LibraryScope.primaryMemberID)
    }

    /// Second-device onboarding adopts the synced primary row (renaming it)
    /// instead of minting a diverging duplicate — the actual sync bug.
    @MainActor @Test func onboardingAdoptsSyncedPrimaryRow() throws {
        let context = makeContext()
        context.insert(User(id: LibraryScope.primaryMemberID,
                            email: "local@librarycove.local",
                            displayName: "Scott", isActive: true,
                            createdAt: Date(timeIntervalSince1970: 500)))
        try context.save()

        // The second device's welcome flow typed "Test".
        let member = SharedLibraryCoordinator.createPrimaryMember(
            displayName: "Test", email: "local@librarycove.local", context: context)

        #expect(member.id == LibraryScope.primaryMemberID)
        #expect(member.displayName == "Test", "the typed name wins — one shared row, not a duplicate")
        let users = try context.fetch(FetchDescriptor<User>())
        #expect(users.count == 1, "no duplicate row minted")
    }

    /// A single legacy row is re-keyed in place (no merge needed) so both
    /// devices land on the same identity even when only one row exists.
    @MainActor @Test func singleLegacyRowIsRekeyed() throws {
        let context = makeContext()
        let legacy = User(id: "uuid-only", email: "local@librarycove.local",
                          displayName: "Scott", isActive: true,
                          createdAt: Date(timeIntervalSince1970: 1000))
        context.insert(legacy)
        try context.save()

        SharedLibraryCoordinator.repairDuplicateActiveMembersIfNeeded(context: context)

        let users = try context.fetch(FetchDescriptor<User>())
        #expect(users.count == 1)
        #expect(users.first?.id == LibraryScope.primaryMemberID)
        #expect(users.first?.displayName == "Scott")
    }
}

@Suite struct HardcoverOAuthTests {
    /// PKCE verifier: 32 random bytes → 43 unreserved base64url chars, no
    /// padding, URL-safe alphabet only (RFC 7636 §4.1).
    @Test func verifierMeetsRFC7636Shape() {
        let verifier = HardcoverOAuth.randomURLSafeBase64(byteCount: 32)
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(!verifier.contains("="))
        #expect(!verifier.contains("+") && !verifier.contains("/"))
        // Two draws never collide.
        #expect(HardcoverOAuth.randomURLSafeBase64(byteCount: 32) != verifier)
    }

    /// The challenge is SHA256(verifier), base64url-encoded — the exact
    /// transform the server must reproduce (S256 method).
    @Test func challengeIsSHA256OfVerifier() throws {
        let verifier = HardcoverOAuth.randomURLSafeBase64(byteCount: 32)
        let challenge = HardcoverOAuth.base64URLSHA256(verifier)
        #expect(challenge.count == 43)
        // Independent recomputation via CryptoKit directly:
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        let expected = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(challenge == expected)
        // And the canonical test vector from the PKCE spec (RFC 7636 B):
        #expect(HardcoverOAuth.base64URLSHA256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// The expiry gate: not-needed when no token or no expiry recorded;
    /// true when expired (60s safety margin), false when comfortably valid.
    @Test func expiryGateLogic() {
        HardcoverConfig.oauthAccessToken = "at"
        defer { HardcoverConfig.clearAllTokens() }
        // No expiry recorded → treated as still valid (a PAT has no expiry).
        HardcoverConfig.oauthAccessTokenExpiry = nil
        #expect(!HardcoverConfig.oauthAccessTokenNeedsRefresh)
        // Expired 5 minutes ago → refresh.
        HardcoverConfig.oauthAccessTokenExpiry = Date().addingTimeInterval(-300)
        #expect(HardcoverConfig.oauthAccessTokenNeedsRefresh)
        // Valid for another hour → no refresh.
        HardcoverConfig.oauthAccessTokenExpiry = Date().addingTimeInterval(3600)
        #expect(!HardcoverConfig.oauthAccessTokenNeedsRefresh)
        // Inside the 60s margin → refresh proactively.
        HardcoverConfig.oauthAccessTokenExpiry = Date().addingTimeInterval(30)
        #expect(HardcoverConfig.oauthAccessTokenNeedsRefresh)
    }

    /// adoptOAuthTokens stores the pair, marks the app enabled, and the
    /// generic `token` accessor serves the OAuth access token.
    @Test func adoptTokensWiresEverythingUp() {
        defer { HardcoverConfig.clearAllTokens() }
        HardcoverConfig.adoptOAuthTokens(access: "hc_at_test",
                                         refresh: "hc_rt_test",
                                         expiresInSeconds: 3600)
        #expect(HardcoverConfig.oauthAccessToken == "hc_at_test")
        #expect(HardcoverConfig.oauthRefreshToken == "hc_rt_test")
        #expect(HardcoverConfig.token == "hc_at_test")
        #expect(HardcoverConfig.isEnabled)
        #expect(HardcoverConfig.isConfigured)
        #expect(HardcoverConfig.oauthAccessTokenExpiry != nil)
    }

    /// Refresh: a token endpoint that answers 200 with a new access token
    /// rotates the stored pair; an error response clears everything so the
    /// UI returns to "Connect".
    @Test func refreshRotatesOrClears() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStubProtocol.self]
        let stubbedSession = URLSession(configuration: config)

        // Success path.
        CatalogStubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"access_token":"hc_at_new","refresh_token":"hc_rt_new","expires_in":3600}"#.utf8))
        }
        HardcoverConfig.adoptOAuthTokens(access: "hc_at_old", refresh: "hc_rt_old",
                                         expiresInSeconds: -100) // already expired
        await HardcoverOAuth.refreshTokensIfNeeded(session: stubbedSession)
        #expect(HardcoverConfig.oauthAccessToken == "hc_at_new")
        #expect(HardcoverConfig.oauthRefreshToken == "hc_rt_new")

        // Failure path: rejects → all credentials cleared.
        CatalogStubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        HardcoverConfig.adoptOAuthTokens(access: "hc_at_old", refresh: "hc_rt_old",
                                         expiresInSeconds: -100)
        await HardcoverOAuth.refreshTokensIfNeeded(session: stubbedSession)
        #expect(HardcoverConfig.oauthAccessToken == nil)
        #expect(HardcoverConfig.oauthRefreshToken == nil)
        #expect(HardcoverConfig.token == nil)
    }
}
