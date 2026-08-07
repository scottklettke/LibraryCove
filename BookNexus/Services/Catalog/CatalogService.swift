import Foundation

/// A book found in an external catalog (OpenLibrary / Google Books).
struct CatalogBook: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let title: String
    let authors: [String]
    let isbn: String?
    let publicationYear: Int?
    let genres: [String]
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
}

/// Where a book description should be fetched from.
enum DescriptionSource: String, CaseIterable, Identifiable {
    case openlibrary
    case wikipedia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openlibrary: return "Open Library"
        case .wikipedia: return "Wikipedia"
        }
    }
}

/// Protocol for external catalog providers.
protocol CatalogService: Sendable {
    func search(query: String, preferred: DescriptionSource) async throws -> [CatalogBook]
    func lookup(isbn: String, preferred: DescriptionSource) async throws -> CatalogBook?
}

/// OpenLibrary search + Google Books cover enrichment.
final class OpenLibraryService: CatalogService {
    private let openLibraryURL = URL(string: "https://openlibrary.org")!
    private let googleBooksURL = URL(string: "https://www.googleapis.com/books/v1/volumes")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Search by title/author. Combines OpenLibrary results with Google Books covers.
    func search(query: String, preferred: DescriptionSource = .openlibrary) async throws -> [CatalogBook] {
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
            let genres = doc["subject"] as? [String] ?? []
            let publishers = doc["publisher"] as? [String] ?? []
            let languageList = doc["language"] as? [String] ?? []
            let key = doc["key"] as? String ?? UUID().uuidString

            books.append(CatalogBook(
                id: key,
                title: title,
                authors: Array(authors.prefix(10)),
                isbn: isbn,
                publicationYear: doc["first_publish_year"] as? Int,
                genres: Array(genres.prefix(10)),
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
    func lookup(isbn: String, preferred: DescriptionSource = .openlibrary) async throws -> CatalogBook? {
        let cleaned = isbn.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
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
            genres: subjects.compactMap { $0["name"] as? String }.prefix(10).map { $0 },
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
                    genres: gb["categories"] as? [String] ?? [],
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
            let genres = gb["categories"] as? [String] ?? catalog.genres
            let publisher = gb["publisher"] as? String ?? catalog.publisher
            let pageCount = gb["pageCount"] as? Int ?? catalog.pageCount
            let year = gb["year"] as? Int ?? catalog.publicationYear

            catalog = CatalogBook(
                id: catalog.id,
                title: catalog.title,
                authors: catalog.authors,
                isbn: cleaned,
                publicationYear: year,
                genres: genres,
                publisher: publisher,
                pageCount: pageCount,
                description: description,
                language: catalog.language,
                coverURLs: covers,
                descriptionSource: gb["description"] != nil ? "googlebooks" : catalog.descriptionSource,
                source: catalog.source
            )
        }

        // Gather multiple cover variants from OpenLibrary editions + Google title search.
        let olCovers = await fetchOpenLibraryCovers(isbn: cleaned)
        let gCovers = await fetchGoogleCovers(title: catalog.title, authors: catalog.authors)
        let combined = olCovers + gCovers
        if !combined.isEmpty {
            var merged = catalog.coverURLs
            var seen = Set(merged)
            for url in combined where seen.insert(url).inserted {
                merged.append(url)
            }
            catalog = CatalogBook(
                id: catalog.id, title: catalog.title, authors: catalog.authors, isbn: catalog.isbn,
                publicationYear: catalog.publicationYear, genres: catalog.genres, publisher: catalog.publisher,
                pageCount: catalog.pageCount, description: catalog.description, language: catalog.language,
                coverURLs: merged, descriptionSource: catalog.descriptionSource, source: catalog.source
            )
        }

        if catalog.description == nil, let fetchedDesc = await fetchDescription(for: catalog.title, authors: catalog.authors, preferred: preferred) {
            catalog = CatalogBook(
                id: catalog.id, title: catalog.title, authors: catalog.authors, isbn: catalog.isbn,
                publicationYear: catalog.publicationYear, genres: catalog.genres, publisher: catalog.publisher,
                pageCount: catalog.pageCount, description: fetchedDesc, language: catalog.language,
                coverURLs: catalog.coverURLs, descriptionSource: preferred.rawValue, source: catalog.source
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

    /// Fetch a book description from the preferred source, falling back to the other.
    private func fetchDescription(for title: String, authors: [String], preferred: DescriptionSource) async -> String? {
        let sources: [DescriptionSource] = preferred == .wikipedia
            ? [.wikipedia, .openlibrary]
            : [.openlibrary, .wikipedia]

        for source in sources {
            let desc: String?
            if source == .openlibrary {
                desc = await fetchWorkDescription(for: title, authors: authors)
            } else {
                desc = await fetchWikipediaDescription(for: title, authors: authors)
            }
            if let desc { return desc }
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
}