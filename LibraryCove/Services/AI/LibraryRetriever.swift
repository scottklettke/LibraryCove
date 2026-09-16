import Foundation
import NaturalLanguage

/// App-side retrieval that runs *before* the LLM call, entirely on-device
/// (CPU/Metal via the bundled NaturalLanguage sentence-embedding model — it
/// consumes zero model tokens). It decides which books a question is about so
/// the AI only ever receives a slim title index plus the full details of the
/// matches; the whole library's descriptions/summaries never enter the model's
/// context window.
enum LibraryRetriever {

    /// A retrieved book with its relevance score, ranked best-first.
    struct Hit: Equatable {
        let book: Book
        let score: Double

        // SwiftData `@Model` classes reuse object identity, so two hits for
        // the same book are equal even though `Book` doesn't declare Equatable.
        static func == (lhs: Hit, rhs: Hit) -> Bool { lhs.book === rhs.book }
    }

    /// Returns the books a `query` is most likely about, ranked by relevance
    /// (score descending, then title A–Z), capped at `maxResults`. Returns `[]`
    /// for blank or all-stopword questions (e.g. "what should I read next?") —
    /// the caller then sends just the compact title index, which fits any
    /// context window.
    ///
    /// Tiers are additive:
    /// 1. *Named* — a query token exactly matches a title / author / genre /
    ///    physical-location word: "do I have Dune", "something by Lem", "books
    ///    tagged philosophy".
    /// 2. *Keyword* — a query token matches a word in summary / description /
    ///    notes text: "which book mentions a walrus".
    /// 3. *Semantic* — cosine similarity of sentence embeddings when the query
    ///    has 2+ meaningful words: "sailors hunting a giant white whale" finds
    ///    Moby-Dick even when no literal word overlaps.
    static func retrieve(query: String, books: [Book], maxResults: Int = 10) -> [Hit] {
        let tokens = significantTokens(query)
        guard !tokens.isEmpty else { return [] }

        let bags = books.map(Bag.init)
        var scores: [Book: Double] = [:]

        for bag in bags {
            var score = 0.0
            var keywordMatches = 0
            for token in tokens {
                if bag.namedTokens.contains(token) {
                    score += 3.0
                } else if bag.textTokens.contains(token) {
                    keywordMatches += 1
                }
            }
            score += Double(keywordMatches) * 2.0
            if score > 0 { scores[bag.book] = score }
        }

        // Semantic recall: catches phrasing that shares no literal words with
        // the text. Only fires for multi-word queries (single words are too
        // noisy), and only for books above a similarity floor.
        if tokens.count >= 2 {
            applySemanticBoost(query: query, bags: bags, scores: &scores)
        }

        return scores
            .map { Hit(book: $0.key, score: $0.value) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.book.title.localizedCaseInsensitiveCompare($1.book.title) == .orderedAscending
            }
            .prefix(maxResults)
            .map { $0 }
    }

    /// True when the on-device sentence-embedding model is available (it ships
    /// with iOS 17+). Exposed so tests can gate semantic assertions on it and
    /// still pass on CI without the model asset.
    static var semanticSearchAvailable: Bool {
        NLEmbedding.sentenceEmbedding(for: .english) != nil
    }

    // MARK: - Tiers

    /// Semantic tier gating, calibrated by probing the iOS 17+
    /// `sentenceEmbedding` model: true paraphrases land ~0.34–0.69 similarity,
    /// while unrelated cross-topic pairs cluster in a ~0.2–0.36 band with no
    /// hard cutoff. A lone absolute threshold would admit near-random matches
    /// (a same-subject decoy sat at 0.450 on one query). So a book joins only
    /// when it clears `semanticFloor` *and* sits within `semanticClusterMargin`
    /// of the best-matching book in the library — the top cluster, not every
    /// dot above the floor. Heuristic, not a contract: exact tiers never depend
    /// on it.
    private static let semanticFloor = 0.28
    private static let semanticClusterMargin = 0.10
    private static let semanticMaxHits = 3

    /// Adds `similarity * 2.5` for the top cluster of books (named/keyword
    /// tiers still outrank it: 3.0 and 2.0 per token). Only fires for
    /// multi-word queries — single words are too noisy to embed meaningfully.
    private static func applySemanticBoost(query: String, bags: [Bag], scores: inout [Book: Double]) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let queryVector = embedding.vector(for: query) else { return }
        var ranked: [(book: Book, sim: Double)] = []
        for bag in bags {
            guard let vector = embedding.vector(for: bag.semanticText) else { continue }
            ranked.append((bag.book, cosine(queryVector, vector)))
        }
        guard let best = ranked.map(\.sim).max(), best >= semanticFloor else { return }
        var added = 0
        for (book, sim) in ranked where sim >= semanticFloor && sim >= best - semanticClusterMargin {
            guard added < semanticMaxHits else { break }
            added += 1
            scores[book, default: 0] += sim * 2.5
        }
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var magA = 0.0
        var magB = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let magnitude = magA.squareRoot() * magB.squareRoot()
        return magnitude == 0 ? 0 : dot / magnitude
    }

    // MARK: - Tokenization

    /// The query's meaningful words, lowercased, stopwords and single-char
    /// tokens removed, in original order (duplicates preserved are harmless).
    private static func significantTokens(_ text: String) -> [String] {
        wholeWords(text)
            .filter { token in
                // Keep numeric tokens ("book 1984") — they only ever match a
                // title/genre containing the exact word, so they can't be noisy.
                token.count >= 2 && !stopwords.contains(token)
            }
            .sorted()
    }

    private static func wholeWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }

    /// Function words and question scaffolding — dropping them keeps named
    /// matching precise ("do I have..." → "Dune" is the only real token).
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with",
        "about", "at", "by", "from", "into", "over", "than", "as", "like",
        "what", "which", "who", "whom", "when", "where", "why", "how",
        "is", "are", "was", "were", "be", "been", "being", "do", "does",
        "did", "i", "me", "my", "mine", "we", "our", "ours", "you", "your",
        "it", "its", "this", "that", "these", "those", "there", "their",
        "they", "them", "any", "all", "some", "none", "not", "no", "if",
        "then", "else", "will", "would", "can", "could", "should", "shall",
        "read", "reading", "book", "books", "have", "has", "had", "recommend",
        "recommends", "recommendation", "recommendations", "suggest",
        "suggests", "suggestion", "suggestions", "tell", "thanks", "please",
    ]

    // MARK: - Book index

    /// Precomputed per-book search fields so a single scan matches every tier.
    private struct Bag {
        let book: Book
        /// Words a user would use to *name* the book: title, authors, tags,
        /// physical location. Matches here are the strongest signal.
        let namedTokens: Set<String>
        /// Named words plus everything searchable in the body text
        /// (summary / description / notes).
        let textTokens: Set<String>
        /// The title + description + summary used for the semantic embedding.
        let semanticText: String

        init(book: Book) {
            self.book = book
            let title = book.title
            let authors = book.authors.joined(separator: " ")
            let tags = book.tags.joined(separator: " ")
            let series = book.series ?? ""
            let location = book.physicalLocation ?? ""
            let description = book.bookDescription ?? ""
            let notes = book.notes?.map(\.content).joined(separator: " ") ?? ""

            let named = Self.words(title + " " + authors + " " + tags + " " + (book.genre ?? "") + " " + series + " " + location)
            // Fields are deliberately capped before tokenizing so one giant
            // description can't drown the index; the snapshot still carries
            // full detail for retrieved books.
            let body = Self.words(
                String((description + " " + notes).prefix(4000))
            )
            namedTokens = named
            textTokens = named.union(body)
            // Omit empty segments (a lone ". . ." measurably degraded embedding
            // similarity in calibration). Kept short: 600 chars of description
            // is plenty for sentence-level meaning.
            var semantic: [String] = []
            if !title.isEmpty { semantic.append(title) }
            if !authors.isEmpty { semantic.append(authors) }
            if !description.isEmpty { semantic.append(String(description.prefix(600))) }
            semanticText = semantic.joined(separator: ". ")
        }

        private static func words(_ text: String) -> Set<String> {
            Set(
                text.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
                    .filter { !$0.isEmpty }
            )
        }
    }
}
