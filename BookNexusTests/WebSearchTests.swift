import Testing
import Foundation
@testable import BookNexus

@Suite
struct WebSearchTests {

    // MARK: - DuckDuckGo HTML parsing

    private let sampleDDGHTML = """
    <html><body>
    <div class="result results_links_deep web_result">
      <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2F&rut=a1">Example &amp; Co</a>
      <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2F&rut=a1">First <b>snippet</b> text.</a>
    </div>
    <div class="result results_links_deep web_result">
      <a rel="nofollow" class="result__a" href="https://plain.org/page">Plain Page</a>
      <a class="result__snippet" href="https://plain.org/page">Second snippet.</a>
    </div>
    </body></html>
    """

    @Test func parsesDuckDuckGoResultsWithURLsTitlesAndSnippets() {
        let results = WebSearch.parseDuckDuckGoHTML(Data(sampleDDGHTML.utf8))
        #expect(results.count == 2)
        #expect(results[0].title == "Example & Co")
        #expect(results[0].url == "https://example.com/") // uddg-wrapped URL decoded
        #expect(results[0].snippet == "First snippet text.") // HTML tags stripped
        #expect(results[1].title == "Plain Page")
        #expect(results[1].url == "https://plain.org/page")
        #expect(results[1].snippet == "Second snippet.")
    }

    @Test func duckDuckGoRealURLDecoding() {
        #expect(WebSearch.realURL(fromDuckDuckGoHref: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.com%2Fx&rut=1")
                == "https://a.com/x")
        // Plain hrefs pass through untouched.
        #expect(WebSearch.realURL(fromDuckDuckGoHref: "https://plain.org") == "https://plain.org")
    }

    @Test func decodeEntitiesHandlesNamedAndNumeric() {
        #expect(WebSearch.decodeEntities("A &amp; B &lt;x&gt; &#39;s C&quot;D&#233;") == "A & B <x> 's C\"D\u{00E9}")
    }

    // MARK: - Wikipedia

    @Test func wikipediaSearchTitleAndExtractParsing() {
        let searchData = Data(#"{"query":{"search":[{"title":"Dune (novel)"}]}}"#.utf8)
        #expect(WebSearch.firstWikipediaSearchTitle(searchData) == "Dune (novel)")

        let extractData = Data(#"{"query":{"pages":{"123":{"pageid":123,"title":"Dune (novel)","extract":"Dune is a 1965 epic science fiction novel."}}}}"#.utf8)
        #expect(WebSearch.wikipediaExtract(from: extractData) == "Dune is a 1965 epic science fiction novel.")
    }

    // MARK: - Grounding block

    @Test func groundingBlockListsSourcesAndIsEmptyWithoutThem() {
        let sources = [
            WebResult(title: "Dune (novel)", url: "https://example.org/dune", snippet: "An epic sci-fi novel."),
            WebResult(title: "Second", url: "https://example.org/2", snippet: "More text."),
        ]
        let block = WebSearch.groundingBlock(sources: sources)
        #expect(block.contains("https://example.org/dune"))
        #expect(block.contains("[1] Dune (novel)"))
        #expect(block.contains("[2] Second"))
        #expect(WebSearch.groundingBlock(sources: []) == "")
    }

    @Test func dedupeAndTruncate() {
        let a = WebResult(title: "T", url: "https://x.com", snippet: "s")
        #expect(WebSearch.dedupe([a, WebResult(title: "t", url: "HTTPS://X.COM", snippet: "s2")]).count == 1)
        #expect(WebSearch.truncate("hello", to: 3) == "hel…")
    }
}

@Suite
struct DescriptionSourceTests {
    @Test func pickerOptionsIncludeAllSupportedSources() {
        // The edit form's Source picker iterates allCases, so every source
        // here must actually be fetchable.
        #expect(DescriptionSource.allCases == [.openlibrary, .wikipedia, .googlebooks])
        #expect(DescriptionSource.googlebooks.displayName == "Google Books")
    }
}
