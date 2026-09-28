import Foundation

/// A metadata record assembled from Hardcover's public catalog: exactly the
/// fields LibraryCove can merge into an imported/importing book. Deliberately
/// excludes ratings, reviews, reading stats, and anything user-owned.
struct HardcoverBookMetadata: Equatable, Sendable {
    /// Hardcover's internal book id (stable, useful for support/debug).
    let bookID: Int?
    let genres: [String]
    /// Community tags across categories (genre, mood, format…), already
    /// flattened and spoiler-filtered.
    let tags: [String]
    /// Series name, e.g. "The Stormlight Archive", with its position if the
    /// book is numbered ("3").
    let seriesName: String?
    let seriesPosition: String?
    let description: String?
    let pageCount: Int?
    /// ISO-2 language code, e.g. "en".
    let language: String?
    let coverImageURL: String?

    var hasEnrichment: Bool {
        !genres.isEmpty || !tags.isEmpty || seriesName != nil
            || description != nil || pageCount != nil || language != nil
            || coverImageURL != nil
    }
}

/// Client for Hardcover's GraphQL API (https://docs.hardcover.app). Reads
/// ONLY public catalog data — every query stays inside the `read:catalog`
/// scope (editions/books/series/tags/images); no ratings, reviews, or
/// user-library fields are ever requested.
///
/// Auth: each user supplies their own Personal Access Token from
/// https://hardcover.app/account/api — the API has no anonymous or
/// app-shared token mode ("Token is not associated with a user" otherwise),
/// and Hardcover explicitly asks that PATs never be shared. The token lives
/// in the Keychain via `HardcoverConfig`; when absent the service is inert
/// and every lookup returns nil, so callers need no existence checks.
///
/// Rate limits (free plan): 5,000/day, 60/min, burst 10 — generous for a
/// personal scanner; requests are additionally serialized to stay polite.
/// The API is in beta and may change; every failure degrades to nil so the
/// app keeps working without it.
final class HardcoverService: Sendable {
    static let apiURL = URL(string: "https://api.hardcover.app/v1/graphql")!

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = [
            "User-Agent": "LibraryCove/0.5 (https://github.com/scottklettke/LibraryCove; librarycove@fastmail.com)"
        ]
        return config
    }())) {
        self.session = session
    }

    // MARK: - Queries

    /// One GraphQL request: find the edition by ISBN-13/10 and pull the
    /// book's enrichment in the same round-trip. Single top-level operation
    /// (the API caps requests at 5).
    private static func enrichmentQuery(isbn13: String?, isbn10: String?) -> String {
        let isbnFilter: String
        if let isbn13, let isbn10, isbn13 != isbn10 {
            isbnFilter = "_or: [{isbn_13: {_eq: \"\(isbn13)\"}}, {isbn_10: {_eq: \"\(isbn10)\"}}]"
        } else if let isbn13 {
            isbnFilter = "isbn_13: {_eq: \"\(isbn13)\"}"
        } else if let isbn10 {
            isbnFilter = "isbn_10: {_eq: \"\(isbn10)\"}"
        } else {
            isbnFilter = "id: {_eq: -1}" // never matches; keeps the query valid
        }
        return """
        query EnrichByISBN {
          editions(where: { \(isbnFilter) }, limit: 1) {
            id
            pages
            language { code2 }
            image { url }
            book {
              id
              description
              cached_tags
              book_series(limit: 1, order_by: { position: asc }) {
                position
                series { name }
              }
            }
          }
        }
        """
    }

    // MARK: - Public API

    /// Look up enrichment for an ISBN (either form). nil = not found,
    /// disabled, or any error — callers treat all three identically.
    func metadata(isbn: String) async -> HardcoverBookMetadata? {
        guard HardcoverConfig.token != nil else { return nil }
        let cleaned = Book.normalizedISBN(isbn)
        guard let cleaned else { return nil }
        let isbn13: String?, isbn10: String?
        if cleaned.count == 13 {
            isbn13 = cleaned
            isbn10 = nil
        } else {
            isbn13 = nil
            isbn10 = cleaned
        }
        return await query(isbn13: isbn13, isbn10: isbn10)
    }

    /// Verify the configured token works: cheapest possible read-catalog
    /// request. Returns an error string on failure, nil on success.
    func testConnection() async -> String? {
        guard let token = HardcoverConfig.token else { return "No API key set." }
        let request = Self.request(query: #"query Ping { books(limit: 1) { id } }"#, token: token)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "Unexpected response." }
            switch http.statusCode {
            case 200:
                // Hasura answers 200 with GraphQL errors in the body; check.
                if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   body["errors"] != nil {
                    return "Key rejected by Hardcover."
                }
                return nil
            case 401: return "Invalid or expired key."
            case 429: return "Rate limited — try again in a minute."
            default: return "Hardcover returned HTTP \(http.statusCode)."
            }
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Plumbing

    private static func request(query: String, token: String) -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        return request
    }

    private func query(isbn13: String?, isbn10: String?) async -> HardcoverBookMetadata? {
        guard let token = HardcoverConfig.token else { return nil }
        let request = Self.request(query: Self.enrichmentQuery(isbn13: isbn13, isbn10: isbn10), token: token)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["errors"] == nil,
                  let result = body["data"] as? [String: Any],
                  let editions = result["editions"] as? [[String: Any]],
                  let edition = editions.first else {
                return nil
            }
            return Self.parse(edition: edition)
        } catch {
            return nil
        }
    }

    // MARK: - Parsing

    /// `cached_tags` arrives as {"Genre": ["Fantasy", …], "Mood": ["Dark"], …}
    /// (observed in the wild; it's a jsonb column so the shape is loosely
    /// typed). Flatten all categories into one tag list; drop spoiler-marked
    /// entries when the platform sends objects.
    static func parse(edition: [String: Any]) -> HardcoverBookMetadata {
        let book = edition["book"] as? [String: Any] ?? [:]

        var tags: [String] = []
        var genres: [String] = []
        if let cached = book["cached_tags"] {
            flattenTags(cached, into: &tags, genres: &genres)
        }

        var seriesName: String?
        var seriesPosition: String?
        if let seriesList = book["book_series"] as? [[String: Any]],
           let entry = seriesList.first {
            if let series = entry["series"] as? [String: Any] {
                seriesName = series["name"] as? String
            }
            if let position = entry["position"] {
                seriesPosition = "\(position)"
            }
        }

        var language: String?
        if let lang = edition["language"] as? [String: Any] {
            language = lang["code2"] as? String
        }
        var coverImageURL: String?
        if let image = edition["image"] as? [String: Any] {
            coverImageURL = image["url"] as? String
        }

        return HardcoverBookMetadata(
            bookID: book["id"] as? Int,
            genres: genres,
            tags: tags,
            seriesName: seriesName,
            seriesPosition: seriesPosition,
            description: book["description"] as? String,
            pageCount: edition["pages"] as? Int,
            language: language,
            coverImageURL: coverImageURL
        )
    }

    /// Recursively flattens the jsonb `cached_tags` payload. Handles both
    /// observed shapes: {category: [tag, …]} dicts and [{tag, tagSlug,
    /// category, spoiler}, …] object lists. Genre-category tags double as
    /// genres; everything lands in `tags`.
    private static func flattenTags(_ payload: Any, into tags: inout [String], genres: inout [String]) {
        var seen = Set<String>()
        func add(_ raw: String, category: String?) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            tags.append(value)
            if let category, category.lowercased().contains("genre") {
                genres.append(value)
            }
        }
        switch payload {
        case let dict as [String: Any]:
            for (category, value) in dict {
                if let list = value as? [Any] {
                    for item in list { add(String(describing: item), category: category) }
                } else if let s = value as? String {
                    add(s, category: category)
                }
            }
        case let list as [Any]:
            for item in list {
                guard let obj = item as? [String: Any] else { continue }
                if let spoiler = obj["spoiler"] as? Bool, spoiler { continue }
                if let tag = obj["tag"] as? String {
                    add(tag, category: obj["category"] as? String)
                }
            }
        default:
            break
        }
    }
}

/// Persisted Hardcover settings: enabled flag in UserDefaults, PAT in the
/// Keychain (never UserDefaults). Mirrors AIConfig's storage discipline.
enum HardcoverConfig {
    private enum Keys {
        static let enabled = "Hardcover.enabled"
        static let keychainService = "com.librarycove.app"
        static let keychainAccount = "HardcoverAPIToken"
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// The PAT, read/written through the Keychain. Writing nil/empty deletes.
    static var token: String? {
        get {
            let value = Keychain.read(service: Keys.keychainService, account: Keys.keychainAccount) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, service: Keys.keychainService, account: Keys.keychainAccount)
            } else {
                Keychain.delete(service: Keys.keychainService, account: Keys.keychainAccount)
            }
        }
    }

    static var isConfigured: Bool { isEnabled && token != nil }
}
