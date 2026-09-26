import Foundation

/// A single retrieved web source for grounding chat answers.
struct WebResult: Sendable, Equatable, Identifiable {
    let title: String
    let url: String
    let snippet: String
    var id: String { url.isEmpty ? title : url }
}

/// Keyless "focused web read" for Ask AI. No API keys, no accounts: it queries
/// permissive sources — a Wikipedia article (clean intro extract) and the
/// DuckDuckGo HTML endpoint (titles + snippets + URLs) — and hands the raw
/// results to the model, which reads and cites them. Every failure degrades to
/// an empty list; the chat never blocks on this.
enum WebSearch {

    static let defaultLimit = 5

    private static let ddgEndpoint = "https://html.duckduckgo.com/html/"
    private static let wikipediaAPI = "https://en.wikipedia.org/w/api.php"
    private static let userAgent = "LibraryCove/0.5 (Ask AI grounding)"

    /// Gathers grounding sources for a plain-language query: the best
    /// Wikipedia article first (when one matches), then DuckDuckGo results.
    static func results(for query: String, limit: Int = defaultLimit) async -> [WebResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var sources: [WebResult] = []
        if let wiki = await wikipediaArticle(for: trimmed) {
            sources.append(wiki)
        }
        sources += await duckDuckGo(for: trimmed)
        return Self.dedupe(sources).prefix(limit).map { $0 }
    }

    /// A compact block to inject into the chat prompt. Empty when there are no
    /// sources, so callers can skip grounding entirely.
    static func groundingBlock(sources: [WebResult]) -> String {
        guard !sources.isEmpty else { return "" }
        let lines = sources.enumerated().map { index, result -> String in
            let snippet = truncate(result.snippet, to: 400)
            return "[\(index + 1)] \(result.title) — \(result.url)\n   \(snippet)"
        }.joined(separator: "\n")
        return """
        Relevant web sources (use them when they help, and cite the number/URL of anything you rely on):

        \(lines)
        """
    }

    // MARK: - Wikipedia

    static func wikipediaArticle(for query: String) async -> WebResult? {
        var searchComponents = URLComponents(string: wikipediaAPI)!
        searchComponents.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let searchURL = searchComponents.url,
              let data = await fetch(searchURL),
              let pageTitle = Self.firstWikipediaSearchTitle(data),
              let extract = await wikipediaExtract(pageTitle: pageTitle),
              !extract.isEmpty else { return nil }
        guard let slug = pageTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return WebResult(title: pageTitle,
                         url: "https://en.wikipedia.org/wiki/\(slug)",
                         snippet: truncate(extract, to: 600))
    }

    static func wikipediaExtract(pageTitle: String) async -> String? {
        var components = URLComponents(string: wikipediaAPI)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "exintro", value: "true"),
            URLQueryItem(name: "explaintext", value: "true"),
            URLQueryItem(name: "titles", value: pageTitle),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url, let data = await fetch(url) else { return nil }
        return Self.wikipediaExtract(from: data)
    }

    /// `query.search[0].title` from the MediaWiki search response.
    static func firstWikipediaSearchTitle(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let search = query["search"] as? [[String: Any]],
              let first = search.first,
              let title = first["title"] as? String else { return nil }
        return title
    }

    /// `query.pages.*.extract` (string) from the MediaWiki extract response.
    static func wikipediaExtract(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any] else { return nil }
        for (_, value) in pages {
            guard let page = value as? [String: Any],
                  let extract = page["extract"] as? String,
                  !extract.isEmpty else { continue }
            return extract
        }
        return nil
    }

    // MARK: - DuckDuckGo (keyless general web search)

    static func duckDuckGo(for query: String) async -> [WebResult] {
        var components = URLComponents(string: ddgEndpoint)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url, let data = await fetch(url) else { return [] }
        return Self.parseDuckDuckGoHTML(data)
    }

    /// Extracts result anchors (`class="result__a"`, URL + title) paired with
    /// their snippets (`class="result__snippet"`) in document order.
    static func parseDuckDuckGoHTML(_ data: Data) -> [WebResult] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        let anchors = Self.matches(in: html,
                                   pattern: #"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#,
                                   groupCount: 2)
        let snippets = Self.matches(in: html,
                                    pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#,
                                    groupCount: 1)
        var results: [WebResult] = []
        for (index, anchor) in anchors.enumerated() {
            guard anchor.count >= 3 else { continue }
            // Group 0 is the whole match; group 1 = href, group 2 = title.
            let rawURL = Self.decodeEntities(anchor[1])
            let url = Self.realURL(fromDuckDuckGoHref: rawURL) ?? rawURL
            let title = Self.stripHTMLTags(Self.decodeEntities(anchor[2])).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = index < snippets.count
                ? Self.stripHTMLTags(Self.decodeEntities(snippets[index][1])).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            guard !title.isEmpty, !url.isEmpty, !url.lowercased().hasPrefix("javascript:") else { continue }
            results.append(WebResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// DuckDuckGo wraps real URLs in `/l/?uddg=<encoded>`. Pull it out when
    /// present, otherwise accept the href as-is.
    static func realURL(fromDuckDuckGoHref href: String) -> String? {
        guard let comps = URLComponents(string: href),
              let item = comps.queryItems?.first(where: { $0.name == "uddg" }),
              let encoded = item.value else { return href }
        return encoded.removingPercentEncoding ?? href
    }

    /// Minimal HTML-entity decoding for titles/snippets (&amp; &#39; &#123; etc.).
    /// Does NOT strip tags — callers that want rendered text apply
    /// `stripHTMLTags` separately.
    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
        ]
        for (from, to) in named {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return decodeNumericEntities(result)
    }

    /// Removes leftover HTML tags (DuckDuckGo highlights query terms with
    /// `<b>` inside titles/snippets).
    static func stripHTMLTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        var s = text
        guard let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) else { return s }
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: s),
                  let num = Range(match.range(at: 1), in: s),
                  let value = UInt32(s[num]),
                  let scalar = Unicode.Scalar(value) else { continue }
            s.replaceSubrange(whole, with: String(scalar))
        }
        return s
    }

    // MARK: - Helpers

    static func dedupe(_ sources: [WebResult]) -> [WebResult] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id.lowercased()).inserted }
    }

    static func truncate(_ s: String, to limit: Int) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "…"
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func matches(in text: String, pattern: String, groupCount: Int) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            (0...groupCount).map { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound, let r = Range(range, in: text) else { return "" }
                return String(text[r])
            }
        }
    }
}
