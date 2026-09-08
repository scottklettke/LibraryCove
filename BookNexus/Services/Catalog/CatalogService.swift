import Foundation

/// A book found in an external catalog (OpenLibrary / Google Books).
struct CatalogBook: Identifiable, Sendable, Equatable, Hashable, Codable {
    let id: String
    let title: String
    let authors: [String]
    let isbn: String?
    let publicationYear: Int?
    let tags: [String]
    let publisher: String?
    let pageCount: Int?
    var description: String?
    let language: String?
    /// Multiple available cover image URLs (thumbnails / full size).
    let coverURLs: [String]
    var descriptionSource: String?
    let source: String

    var authorsText: String { authors.isEmpty ? "Unknown" : authors.joined(separator: ", ") }
    var primaryCoverURL: String? { coverURLs.first }

    /// A placeholder for a scanned-but-not-found ISBN so the book can still be
    /// added with manually entered details. ISBN normalized via the shared
    /// canonical form (13 digits).
    static func manualStub(isbn: String) -> CatalogBook {
        let cleaned = Book.normalizedISBN(isbn) ?? ""
        return CatalogBook(id: "isbn-\(cleaned)",
                           title: "",
                           authors: [],
                           isbn: cleaned,
                           publicationYear: nil,
                           tags: [],
                           publisher: nil,
                           pageCount: nil,
                           description: nil,
                           language: nil,
                           coverURLs: [],
                           descriptionSource: nil,
                           source: "manual")
    }
}

/// Where a book description should be fetched from.
enum DescriptionSource: String, CaseIterable, Identifiable {
    case openlibrary
    case wikipedia
    case googlebooks

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openlibrary: return "Open Library"
        case .wikipedia: return "Wikipedia"
        case .googlebooks: return "Google Books"
        }
    }

    /// Display label for a stored source string (a rawValue, or several
    /// comma-joined parts when identical texts were merged across sources).
    /// Known catalog sources map to display names; unknown parts (a website
    /// hostname captured from the in-app browser import) pass through
    /// verbatim. `nil` means the text has no known origin ("Current text").
    static func label(for raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Current text" }
        let names = raw.split(separator: ",").map { part in
            DescriptionSource(rawValue: String(part))?.displayName ?? String(part)
        }
        return names.joined(separator: " · ")
    }
}

/// Protocol for external catalog providers.
protocol CatalogService: Sendable {
    func search(query: String, preferred: DescriptionSource) async throws -> [CatalogBook]
    func lookup(isbn: String, preferred: DescriptionSource) async throws -> CatalogBook?
}


/// Runs `work` with a hard wall-clock cap: whichever finishes first wins
/// and the loser is cancelled. Request-level timeouts bound every network
/// call, but a lookup is a CHAIN of calls (record + enrichment + covers +
/// description fallbacks) — on a flaky network that chain can stretch for
/// minutes. The cap turns an endless "Fetching description…" spinner into a
/// timed-out result the caller can surface and retry.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ work: @escaping @Sendable () async -> T?
) async -> (value: T?, timedOut: Bool) {
    await withTaskGroup(of: (value: T?, timedOut: Bool).self) { group in
        group.addTask { (value: await work(), timedOut: false) }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return (value: nil, timedOut: true)
        }
        let first = await group.next() ?? (value: nil, timedOut: true)
        group.cancelAll()
        return first
    }
}

/// OpenLibrary search + Google Books cover enrichment.
final class OpenLibraryService: CatalogService {
    private let openLibraryURL = URL(string: "https://openlibrary.org")!
    private let googleBooksURL = URL(string: "https://www.googleapis.com/books/v1/volumes")!
    private let session: URLSession

    /// Catalog lookups run in the background scan queue, so a request must
    /// never hang the queue: bound every request with a short timeout instead
    /// of `URLSession.shared`'s multi-minute defaults. A peer that blackholes
    /// (connects but never responds) then becomes a `.failed` item the user can
    /// retry rather than an infinite "looking up" spinner.
    private static func boundedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    init(session: URLSession = OpenLibraryService.boundedSession()) {
        self.session = session
    }

    /// Search by title/author. Combines OpenLibrary results with Google Books covers.
    func search(query: String, preferred: DescriptionSource = .wikipedia) async throws -> [CatalogBook] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "fields", value: "key,title,author_name,isbn,cover_i,subject,publisher,first_publish_year,language,number_of_pages_median"),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let docs = json?["docs"] as? [[String: Any]] ?? []

        var books: [CatalogBook] = []
        for doc in docs {
            let title = doc["title"] as? String ?? ""
            if title.isEmpty { continue }
            let authors = doc["author_name"] as? [String] ?? []
            let isbnList = doc["isbn"] as? [String] ?? []
            let isbn = isbnList.first
            let coverID = doc["cover_i"] as? Int
            var coverURLs: [String] = []
            if let coverID {
                coverURLs.append("https://covers.openlibrary.org/b/id/\(coverID)-S.jpg")
                coverURLs.append("https://covers.openlibrary.org/b/id/\(coverID)-M.jpg")
                coverURLs.append("https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")
            }
            let tags = doc["subject"] as? [String] ?? []
            let publishers = doc["publisher"] as? [String] ?? []
            let languageList = doc["language"] as? [String] ?? []
            let key = doc["key"] as? String ?? UUID().uuidString

            books.append(CatalogBook(
                id: key,
                title: title,
                authors: Array(authors.prefix(10)),
                isbn: isbn,
                publicationYear: doc["first_publish_year"] as? Int,
                tags: Array(tags.prefix(10)),
                publisher: publishers.first,
                pageCount: doc["number_of_pages_median"] as? Int,
                description: nil,
                language: languageList.first,
                 coverURLs: coverURLs,
                descriptionSource: nil,
            source: "openlibrary"
            ))
        }

        return books
    }

    /// Look up a book by ISBN via OpenLibrary, then enrich with Google Books.
    func lookup(isbn: String, preferred: DescriptionSource = .wikipedia) async throws -> CatalogBook? {
        guard let cleaned = Book.normalizedISBN(isbn) else { return nil }
        var components = URLComponents(string: "https://openlibrary.org/api/books")!
        components.queryItems = [
            URLQueryItem(name: "bibkeys", value: "ISBN:\(cleaned)"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "jscmd", value: "data"),
        ]
        guard let url = components.url else { return nil }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let book = json?["ISBN:\(cleaned)"] as? [String: Any]

        let title = book?["title"] as? String ?? ""
        let authors = (book?["authors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let coverOptions = book?["cover"] as? [String: Any]
        let coverURL = coverOptions?["large"] as? String ?? coverOptions?["medium"] as? String
        let publishers = book?["publishers"] as? [[String: Any]] ?? []
        let subjects = book?["subjects"] as? [[String: Any]] ?? []
        let publishDate = book?["publish_date"] as? String ?? ""

        var catalog = CatalogBook(
            id: "isbn-\(cleaned)",
            title: title,
            authors: authors,
            isbn: cleaned,
            publicationYear: Self.year(from: publishDate),
            tags: subjects.compactMap { $0["name"] as? String }.prefix(10).map { $0 },
            publisher: publishers.first?["name"] as? String,
            pageCount: book?["number_of_pages"] as? Int,
            description: book?["description"] as? String,
            language: nil,
            coverURLs: [coverURL].compactMap { $0 },
            descriptionSource: "openlibrary",
            source: "openlibrary"
        )

        if title.isEmpty {
            // Fallback straight to Google Books by ISBN.
            let gb = await googleResult(isbn: cleaned)
            if let gb, let t = gb["title"] as? String, !t.isEmpty {
                catalog = CatalogBook(
                    id: "isbn-\(cleaned)",
                    title: t,
                    authors: gb["authors"] as? [String] ?? [],
                    isbn: cleaned,
                    publicationYear: gb["year"] as? Int,
                    tags: gb["categories"] as? [String] ?? [],
                    publisher: gb["publisher"] as? String,
                    pageCount: gb["pageCount"] as? Int,
                    description: gb["description"] as? String,
                    language: nil,
                     coverURLs: (gb["covers"] as? [String]) ?? [],
                    descriptionSource: "googlebooks",
                source: "googlebooks"
                )
            }
        } else if let gb = await googleResult(isbn: cleaned) {
            var covers = catalog.coverURLs
            if let gcovers = gb["covers"] as? [String] { covers.append(contentsOf: gcovers) }
            let description = gb["description"] as? String ?? catalog.description
            let tags = gb["categories"] as? [String] ?? catalog.tags
            let publisher = gb["publisher"] as? String ?? catalog.publisher
            let pageCount = gb["pageCount"] as? Int ?? catalog.pageCount
            let year = gb["year"] as? Int ?? catalog.publicationYear

            catalog = CatalogBook(
                id: catalog.id,
                title: catalog.title,
                authors: catalog.authors,
                isbn: cleaned,
                publicationYear: year,
                tags: tags,
                publisher: publisher,
                pageCount: pageCount,
                description: description,
                language: catalog.language,
                coverURLs: covers,
                descriptionSource: (gb["description"] as? String).flatMap { gbDesc in
                    gbDesc != catalog.description ? "googlebooks" : nil
                } ?? catalog.descriptionSource,
                source: catalog.source
            )
        }

        // Gather multiple cover variants from OpenLibrary editions + Google
        // title search. The two sources are independent — fetch them
        // concurrently so scan-time lookups don't serialize one behind the other.
        async let olCovers = fetchOpenLibraryCovers(isbn: cleaned)
        async let gCovers = fetchGoogleCovers(title: catalog.title, authors: catalog.authors)
        let combined = await olCovers + gCovers
        if !combined.isEmpty {
            var merged = catalog.coverURLs
            var seen = Set(merged)
            for url in combined where seen.insert(url).inserted {
                merged.append(url)
            }
            catalog = CatalogBook(
                id: catalog.id, title: catalog.title, authors: catalog.authors, isbn: catalog.isbn,
                publicationYear: catalog.publicationYear, tags: catalog.tags, publisher: catalog.publisher,
                pageCount: catalog.pageCount, description: catalog.description, language: catalog.language,
                coverURLs: merged, descriptionSource: catalog.descriptionSource, source: catalog.source
            )
        }

        if catalog.description == nil, let fetched = await fetchDescription(for: catalog.title, authors: catalog.authors, preferred: preferred) {
            catalog = CatalogBook(
                id: catalog.id, title: catalog.title, authors: catalog.authors, isbn: catalog.isbn,
                publicationYear: catalog.publicationYear, tags: catalog.tags, publisher: catalog.publisher,
                pageCount: catalog.pageCount, description: fetched.text, language: catalog.language,
                coverURLs: catalog.coverURLs, descriptionSource: fetched.source.rawValue, source: catalog.source
            )
        }

        return catalog.title.isEmpty ? nil : catalog
    }
    /// Fetch multiple cover variants for an ISBN from OpenLibrary.
    /// Reads the edition's `covers` array (multiple cover IDs), then follows
    /// the `works` key to `/editions.json` to gather covers from every printing.
    private func fetchOpenLibraryCovers(isbn: String) async -> [String] {
        var covers: [String] = []

        // 1) Edition record: read the covers array (cover IDs).
        if let editionURL = URL(string: "https://openlibrary.org/isbn/\(isbn).json"),
           let (data, response) = try? await session.data(from: editionURL),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            let coverIDs = json["covers"] as? [Int] ?? []
            for id in coverIDs {
                covers.append("https://covers.openlibrary.org/b/id/\(id)-L.jpg")
                covers.append("https://covers.openlibrary.org/b/id/\(id)-M.jpg")
            }

            // 2) Follow works key -> editions.json for covers from other printings.
            let works = json["works"] as? [[String: Any]] ?? []
            let workKey = works.first?["key"] as? String
            if let workKey, let editionsURL = URL(string: "https://openlibrary.org\(workKey)/editions.json"),
               let (edata, eresponse) = try? await session.data(from: editionsURL),
               let ehttp = eresponse as? HTTPURLResponse, ehttp.statusCode == 200,
               let ejson = try? JSONSerialization.jsonObject(with: edata) as? [String: Any],
               let entries = ejson["entries"] as? [[String: Any]] {
                for entry in entries {
                    let eids = entry["covers"] as? [Int] ?? []
                    for id in eids {
                        covers.append("https://covers.openlibrary.org/b/id/\(id)-L.jpg")
                    }
                }
            }
        }

        var seen = Set<String>()
        return covers.filter { seen.insert($0).inserted }
    }

    private func fetchGoogleCovers(title: String, authors: [String]) async -> [String] {
        guard !title.isEmpty else { return [] }
        let query = [title] + authors
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [URLQueryItem(name: "q", value: query.joined(separator: "+"))]
        guard let url = components.url else { return [] }

        var covers: [String] = []
        if let (data, response) = try? await session.data(from: url),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = json["items"] as? [[String: Any]] {
            for item in items {
                if let links = item["volumeInfo"] as? [String: Any],
                   let imageLinks = links["imageLinks"] as? [String: Any],
                   let coverURL = imageLinks["large"] as? String ?? imageLinks["thumbnail"] as? String {
                    covers.append(coverURL)
                }
            }
        }
        var seen = Set<String>()
        return covers.filter { seen.insert($0).inserted }
    }

    /// Fetch a book description from the preferred source, falling back through
    /// the rest. Google Books may be rate-limited keyless, so it is never the
    /// only chance — the others follow if it returns nothing. Returns the
    /// text with the source that actually provided it.
    private func fetchDescription(for title: String, authors: [String], preferred: DescriptionSource) async -> (text: String, source: DescriptionSource)? {
        let sources: [DescriptionSource]
        switch preferred {
        case .wikipedia: sources = [.wikipedia, .googlebooks, .openlibrary]
        case .openlibrary: sources = [.openlibrary, .wikipedia, .googlebooks]
        case .googlebooks: sources = [.googlebooks, .wikipedia, .openlibrary]
        }

        for source in sources {
            let desc: String?
            switch source {
            case .openlibrary:
                desc = await fetchWorkDescription(for: title, authors: authors)
            case .wikipedia:
                desc = await fetchWikipediaDescription(for: title, authors: authors)
            case .googlebooks:
                desc = await googleTitleDescription(title: title, authors: authors)
            }
            if let desc { return (desc, source) }
        }

        return nil
    }
    /// Fallback: fetch a book's description from its OpenLibrary work record
    /// when the ISBN record has none.
    private func fetchWorkDescription(for title: String, authors: [String]) async -> String? {
        guard !title.isEmpty else { return nil }

        var searchComponents = URLComponents(string: "https://openlibrary.org/search.json")!
        var query = title
        if let first = authors.first {
            query += " " + first
        }
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fields", value: "key")
        ]
        guard let searchURL = searchComponents.url else { return nil }

        do {
            let (data, response) = try await session.data(from: searchURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let docs = json["docs"] as? [[String: Any]],
                  let key = docs.first?["key"] as? String else { return nil }

            let workURL = URL(string: "https://openlibrary.org\(key).json")!
            let (workData, workResponse) = try await session.data(from: workURL)
            guard let workHTTP = workResponse as? HTTPURLResponse, workHTTP.statusCode == 200,
                  let workJSON = try? JSONSerialization.jsonObject(with: workData) as? [String: Any],
                  let rawDesc = workJSON["description"] else { return nil }

            let desc: String?
            if let s = rawDesc as? String {
                desc = s
            } else if let dict = rawDesc as? [String: Any], let value = dict["value"] as? String {
                desc = value
            } else {
                desc = nil
            }
            return desc.map { Self.truncate($0) }
        } catch {
            return nil
        }
    }

    // MARK: - Google Books helpers

    private func googleResult(for title: String, authors: [String]) async -> [String: Any]? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        var query = "intitle:\(title)"
        if let first = authors.first {
            query += " inauthor:\(first)"
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "1"),
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let items = json?["items"] as? [[String: Any]] ?? []
            guard let volume = items.first, let info = volume["volumeInfo"] as? [String: Any] else { return nil }
            return self.mapGoogleInfo(info)
        } catch {
            return nil
        }
    }

    private func googleResult(isbn: String) async -> [String: Any]? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "isbn:\(isbn)"),
            URLQueryItem(name: "maxResults", value: "1"),
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let items = json?["items"] as? [[String: Any]] ?? []
            guard let volume = items.first, let info = volume["volumeInfo"] as? [String: Any] else { return nil }
            return self.mapGoogleInfo(info)
        } catch {
            return nil
        }
    }

    private func mapGoogleInfo(_ info: [String: Any]) -> [String: Any] {
        var mapped: [String: Any] = [:]
        mapped["title"] = info["title"] as? String
        mapped["authors"] = info["authors"] as? [String]
        let industry = info["industryIdentifiers"] as? [[String: Any]] ?? []
        if let isbn13 = industry.first(where: { $0["type"] as? String == "ISBN_13" }) {
            mapped["isbn"] = isbn13["identifier"] as? String
        } else if let isbn10 = industry.first(where: { $0["type"] as? String == "ISBN_10" }) {
            mapped["isbn"] = isbn10["identifier"] as? String
        }
        mapped["categories"] = info["categories"] as? [String]
        mapped["publisher"] = info["publisher"] as? String
        let published = info["publishedDate"] as? String ?? ""
        mapped["year"] = Self.year(from: published)
        let desc = info["description"] as? String
        mapped["description"] = desc.map { Self.truncate($0) }
        mapped["pageCount"] = info["pageCount"] as? Int
        if let images = info["imageLinks"] as? [String: Any] {
            mapped["thumbnail"] = images["thumbnail"] as? String
            mapped["large"] = images["large"] as? String
            var covers: [String] = []
            for key in ["smallThumbnail", "thumbnail", "small", "medium", "large", "extraLarge"] {
                if let url = images[key] as? String { covers.append(url) }
            }
            mapped["covers"] = covers
        }
        return mapped
    }

    static func year(from date: String) -> Int? {
        let cleaned = date.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.split(separator: "-").first else { return Int(cleaned) }
        return Int(first)
    }

    /// Fetch a longer description from Wikipedia when OpenLibrary/Google return none.
    private func fetchWikipediaDescription(for title: String, authors: [String]) async -> String? {
        var searchComponents = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        var query = title
        if let first = authors.first {
            query += " " + first
        }
        searchComponents.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let searchURL = searchComponents.url else { return nil }

        do {
            let (data, response) = try await session.data(from: searchURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let queryResult = json["query"] as? [String: Any],
                  let search = queryResult["search"] as? [[String: Any]],
                  let first = search.first, let pageTitle = first["title"] as? String else { return nil }

            var extractComponents = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
            extractComponents.queryItems = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "prop", value: "extracts"),
                URLQueryItem(name: "exintro", value: "true"),
                URLQueryItem(name: "explaintext", value: "true"),
                URLQueryItem(name: "titles", value: pageTitle),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let extractURL = extractComponents.url else { return nil }
            let (extractData, extractResponse) = try await session.data(from: extractURL)
            guard let extractHTTP = extractResponse as? HTTPURLResponse, extractHTTP.statusCode == 200,
                  let extractJSON = try? JSONSerialization.jsonObject(with: extractData) as? [String: Any],
                  let pages = extractJSON["query"] as? [String: Any] else { return nil }
            let pagesDict = pages["pages"] as? [String: Any]
            guard let pagesDict else { return nil }
            let page = pagesDict.values.compactMap { $0 as? [String: Any] }.first
            let extract = page?["extract"] as? String
            return extract.map { Self.truncate($0) }
        } catch {
            return nil
        }
    }

    static func truncate(_ s: String, to limit: Int = 20000) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit))
    }

    // MARK: - Description aggregation (for "Improve description")

    /// Fetches a book's description only when the user is in a detail step (the
    /// add/edit form or "Improve description") — never during search. Returns
    /// the fullest real text available, preferring Wikipedia's article extract
    /// (usually the longest) while still considering OpenLibrary and Google
    /// Books. Title-based sources are consulted even when the ISBN has no
    /// record, so an ISBN that "doesn't come up with anything" still finds a
    /// description by title.
    func richDescription(existing: String?,
                         isbn: String?,
                         title: String,
                         authors: [String]) async -> (text: String?, source: String?) {
        var candidates: [(text: String, source: String?)] = []
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append((existing, nil))
        }
        if let isbn, !isbn.isEmpty {
            if let book = try? await lookup(isbn: isbn, preferred: .wikipedia),
               let desc = book.description,
               !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append((desc, book.descriptionSource))
            }
            if let google = await googleDescription(isbn: isbn) {
                candidates.append((google, "googlebooks"))
            }
        }
        // Title-based sources — the fallback when an ISBN lookup is empty, and
        // the primary source of the fuller Wikipedia extract the user wanted.
        if let wiki = await wikipediaBookExtract(title: title, authors: authors) {
            candidates.append((wiki, "wikipedia"))
        }
        if let ol = await fetchWorkDescription(for: title, authors: authors) {
            candidates.append((ol, "openlibrary"))
        }
        if let google = await googleTitleDescription(title: title, authors: authors) {
            candidates.append((google, "googlebooks"))
        }
        // Longest non-empty candidate wins (whitespace-trimmed so a
        // whitespace-only entry can't win).
        let best = candidates
            .map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), source: $0.source) }
            .filter { !$0.text.isEmpty }
            .max { $0.text.count < $1.text.count }
        return (best?.text, best?.source)
    }

    /// Every description candidate a book has, from all sources at once —
    /// the picker in the add/edit form shows one row per source so the user
    /// can choose the text they like best. Sources run concurrently; results
    func descriptionCandidates(isbn: String?,
                               title: String,
                               authors: [String],
                               current: String?,
                               currentSource: String? = nil) async -> [(text: String, sources: [String?])] {
        var candidates: [(text: String, sources: [String?])] = []
        let trimmedCurrent = current?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        if let trimmedCurrent, !trimmedCurrent.isEmpty {
            candidates.append((trimmedCurrent, [currentSource]))
            seen.insert(trimmedCurrent)
        }

        var fetched: [(text: String, source: String?)] = []
        // The ISBN record's own description first (Wikipedia-preferred order),
        // then the remaining sources by title. Independent — run concurrently.
        async let isbnRecord: (text: String?, source: String?)? = {
            guard let isbn, !isbn.isEmpty,
                  let book = try? await lookup(isbn: isbn, preferred: .wikipedia),
                  let desc = book.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !desc.isEmpty else { return nil }
            return (desc, book.descriptionSource)
        }()
        async let wiki: String? = wikipediaBookExtract(title: title, authors: authors)
        async let ol: String? = fetchWorkDescription(for: title, authors: authors)
        async let googleIsbn: String? = {
            guard let isbn, !isbn.isEmpty else { return nil }
            return await googleDescription(isbn: isbn)
        }()
        async let googleTitle: String? = googleTitleDescription(title: title, authors: authors)
        let (record, w, o, gi, gt) = await (isbnRecord, wiki, ol, googleIsbn, googleTitle)
        if let record, let text = record.text, !text.isEmpty {
            fetched.append((text, record.source))
        }
        if let w, !w.isEmpty { fetched.append((w, "wikipedia")) }
        if let o, !o.isEmpty { fetched.append((o, "openlibrary")) }
        if let gi, !gi.isEmpty { fetched.append((gi, "googlebooks")) }
        if let gt, !gt.isEmpty { fetched.append((gt, "googlebooks")) }
        // Trim before dedupe: the direct sources return truncate() output
        // with edge whitespace while the ISBN record and the current text
        // are trimmed — raw comparison missed those matches and the same
        // Wikipedia article could show up as two rows.
        fetched = fetched.map {
            ($0.text.trimmingCharacters(in: .whitespacesAndNewlines), $0.source)
        }.filter { !$0.text.isEmpty }
        // Dedupe identical texts (the ISBN record and a title hit are often
        // the same publisher blurb), merging their source labels on the first
        // occurrence. The current text dedupes too: when it matches a fetched
        // description the row keeps "current" plus the fetched source(s).
        for candidate in fetched {
            if seen.insert(candidate.text).inserted {
                candidates.append((candidate.text, [candidate.source]))
            } else if let idx = candidates.firstIndex(where: { $0.text == candidate.text }),
                      !candidates[idx].sources.contains(candidate.source) {
                candidates[idx].sources.append(candidate.source)
            }
        }
        return candidates
    }
    /// A single, light title-based description lookup for the add/edit form's
    /// auto-fill: Wikipedia (book-page-gated) preferred, then OpenLibrary's
    /// work record. Used when the ISBN record carries no description, so an
    /// ISBN that lacks a catalog entry still finds text by title without the
    /// full multi-source chain (which stays reserved for "Improve description").
    func descriptionByTitle(title: String, authors: [String], preferred: DescriptionSource) async -> (text: String?, source: String?) {
        guard !title.isEmpty else { return (nil, nil) }
        switch preferred {
        case .openlibrary:
            if let ol = await fetchWorkDescription(for: title, authors: authors) {
                return (ol, "openlibrary")
            }
            if let wiki = await wikipediaBookExtract(title: title, authors: authors) {
                return (wiki, "wikipedia")
            }
            if let google = await googleTitleDescription(title: title, authors: authors) {
                return (google, "googlebooks")
            }
        case .wikipedia:
            if let wiki = await wikipediaBookExtract(title: title, authors: authors) {
                return (wiki, "wikipedia")
            }
            if let ol = await fetchWorkDescription(for: title, authors: authors) {
                return (ol, "openlibrary")
            }
            if let google = await googleTitleDescription(title: title, authors: authors) {
                return (google, "googlebooks")
            }
        case .googlebooks:
            if let google = await googleTitleDescription(title: title, authors: authors) {
                return (google, "googlebooks")
            }
            if let wiki = await wikipediaBookExtract(title: title, authors: authors) {
                return (wiki, "wikipedia")
            }
            if let ol = await fetchWorkDescription(for: title, authors: authors) {
                return (ol, "openlibrary")
            }
        }
        return (nil, nil)
    }

    /// Google Books description by ISBN (Google often has the fullest text).
    private func googleDescription(isbn: String) async -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "isbn:\(isbn)"),
            URLQueryItem(name: "maxResults", value: "1"),
        ]
        guard let url = components.url else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let volume = items.first, let info = volume["volumeInfo"] as? [String: Any],
              let desc = info["description"] as? String,
              !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self.truncate(desc)
    }

    /// Google Books description by title+author — the extra source that still
    /// works when the ISBN has no record.
    private func googleTitleDescription(title: String, authors: [String]) async -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        var query = "intitle:\"\(title)\""
        if let first = authors.first, !first.isEmpty {
            query += " inauthor:\"\(first)\""
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "1"),
        ]
        guard let url = components.url else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let volume = items.first, let info = volume["volumeInfo"] as? [String: Any],
              let desc = info["description"] as? String,
              !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self.truncate(desc)
    }

    /// Wikipedia's article extract for the book — but only when the matched
    /// page's title actually looks like the book (shared substantive words).
    /// This stops a niche book from being described by its author's bio page
    /// (e.g. "No Bad Kids" matching the "Janet Lansbury" biography). Returns
    /// nil when no book-matching page is found.
    private func wikipediaBookExtract(title: String, authors: [String]) async -> String? {
        guard !title.isEmpty else { return nil }
        var searchComponents = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        var query = title
        if let first = authors.first, !first.isEmpty {
            query += " " + first
        }
        searchComponents.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "3"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let searchURL = searchComponents.url,
              let (data, response) = try? await session.data(from: searchURL),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryResult = json["query"] as? [String: Any],
              let search = queryResult["search"] as? [[String: Any]] else { return nil }

        let bookWords = Self.words(title)
        guard let hit = search.first(where: { page in
            guard let pageTitle = page["title"] as? String else { return false }
            return !Self.words(pageTitle).isDisjoint(with: bookWords)
        }), let pageTitle = hit["title"] as? String else { return nil }

        var extractComponents = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        extractComponents.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "exintro", value: "true"),
            URLQueryItem(name: "explaintext", value: "true"),
            URLQueryItem(name: "titles", value: pageTitle),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let extractURL = extractComponents.url,
              let (extractData, extractResponse) = try? await session.data(from: extractURL),
              let extractHTTP = extractResponse as? HTTPURLResponse, extractHTTP.statusCode == 200,
              let extractJSON = try? JSONSerialization.jsonObject(with: extractData) as? [String: Any],
              let pages = extractJSON["query"] as? [String: Any],
              let pagesDict = pages["pages"] as? [String: Any],
              let page = pagesDict.values.compactMap({ $0 as? [String: Any] }).first,
              let extract = page["extract"] as? String,
              !extract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self.truncate(extract)
    }

    /// Substantive words of a string (length ≥ 4, case-folded) used to decide
    /// whether a Wikipedia page is about the book rather than its author.
    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 })
    }
}

/// Web search engines offered for the "Search the web" description escape
/// hatch. Stored as a raw string in `UserDefaults` via `AIConfig`-style
/// accessors; every case builds its own query URL so no engine-specific
/// formatting leaks into call sites.
enum WebSearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, ecosia, kagi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .ecosia: return "Ecosia"
        case .kagi: return "Kagi"
        }
    }

    /// Percent-encoded search URL for a free-form query. Built with
    /// URLComponents so values containing "&" or "=" (think "War & Peace")
    /// stay inside the `q` parameter instead of splitting into fake ones.
    func searchURL(for query: String) -> URL? {
        let base: String
        switch self {
        case .google: base = "https://www.google.com/search"
        case .duckduckgo: base = "https://duckduckgo.com/"
        case .bing: base = "https://www.bing.com/search"
        case .ecosia: base = "https://www.ecosia.org/search"
        case .kagi: base = "https://kagi.com/search"
        }
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// The persisted selection. iOS exposes no API to read Safari's actual
    /// default engine, so the app keeps its own — defaulting to DuckDuckGo
    /// rather than Google by user preference. Change it in Settings → AI.
    static var selected: WebSearchEngine {
        get {
            let raw = UserDefaults.standard.string(forKey: "description.webSearchEngine") ?? ""
            return WebSearchEngine(rawValue: raw) ?? .duckduckgo
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "description.webSearchEngine")
        }
    }
}