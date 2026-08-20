import Foundation

/// An OpenAI-compatible chat-completions provider (works against api.openai.com
/// or any self-hosted /v1 API that mirrors the chat-completions shape).
///
/// The transport (`URLSession`) is injectable so tests can substitute a mock
/// `URLProtocol` and never touch the network.
///
/// Which model the request carries is never hardcoded: with no override the
/// provider consults `GET {base}/v1/models` and uses a chat-capable id the
/// server actually reports (cached briefly). An explicit `model:` override
/// pins requests to that id and skips discovery.
final class OpenAICompatibleProvider: AIModelProviding {

    static var engine: AIEngine { .openAI }
    var engine: AIEngine { .openAI }

    private let baseURL: String
    private let apiKey: String
    private let session: URLSession
    /// Explicit model override. Empty means the request model is discovered
    /// from `GET {base}/v1/models` instead of being hardcoded anywhere.
    private let model: String

    init(baseURL: String, apiKey: String, model: String = "", session: URLSession = OpenAICompatibleProvider.longTimeoutSession()) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Local reasoning endpoints (e.g. a self-hosted DeepSeek) can take well
    /// over a minute for long JSON requests that also spend budget on
    /// chain-of-thought, so the transport must not inherit `URLSession.shared`'s
    /// 60-second request timeout — that's what turned slow lookups into
    /// "timeout after ~60 s" failures. Bound generously instead.
    static func longTimeoutSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func availability() async -> AIAvailability {
        guard !baseURL.isEmpty else {
            return .unavailable("Missing base URL.")
        }
        return .available
    }

    // MARK: - Model discovery

    /// How long a fetched model list is reused. Nobody wants a models probe in
    /// front of every chat request; a 5-minute window keeps interactions fast
    /// while still refreshing the list in Settings.
    private static let modelCacheTTL: TimeInterval = 300

    private struct CachedModelList {
        let infos: [AIModelInfo]
        let fetchedAt: Date
    }

    private static let discoveryLock = NSLock()
    private static var modelListCache: [String: CachedModelList] = [:]
    private static var _lastResolvedModel: String?

    /// The most recently resolved chat model (what the last request actually
    /// carried on the wire), or nil when no request has settled one yet.
    /// Callers (logs, Settings) surface this so the model in use is visible
    /// even when it's auto-discovered rather than pinned.
    static var lastResolvedModel: String? {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        return _lastResolvedModel
    }

    /// Drops the cached model lists and the resolved-model record. Tests use
    /// this between cases so discovery behavior is deterministic.
    static func flushModelCache() {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        modelListCache = [:]
        _lastResolvedModel = nil
    }

    private static func recordResolvedModel(_ id: String) {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        _lastResolvedModel = id.isEmpty ? nil : id
    }

    private static func cacheKey(for baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.replacingOccurrences(
            of: #"[/\\]+$"#, with: "", options: .regularExpression)
        return stripped.lowercased()
    }

    private static func cachedModelInfos(forKey key: String) -> [AIModelInfo]? {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        guard let cached = modelListCache[key],
              Date().timeIntervalSince(cached.fetchedAt) < modelCacheTTL else {
            return nil
        }
        return cached.infos
    }

    private static func storeModelInfos(_ infos: [AIModelInfo], forKey key: String) {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        modelListCache[key] = CachedModelList(infos: infos, fetchedAt: Date())
    }

    /// Normalizes a user-typed base URL into a model-list endpoint, parallel
    /// to `chatCompletionsURL`:
    /// - already `…/models` → used as-is
    /// - already ends in `/v1` → `…/v1/models`
    /// - anything else → `…/v1/models`
    static func modelsURL(for baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/models") {
            return URL(string: base)
        }
        let prefix = base.hasSuffix("/v1") ? base : "\(base)/v1"
        return URL(string: "\(prefix)/models")
    }

    /// GETs `{base}/v1/models` and returns the server's model entries (id plus
    /// whatever metadata the server publishes — name, context window) sorted by
    /// id. Reuses the same status/decoding/network error mapping as chat so
    /// failures surface consistently. Results are cached for `modelCacheTTL`
    /// keyed on the normalized endpoint.
    func listModelInfos() async throws -> [AIModelInfo] {
        guard !baseURL.isEmpty else { throw AIError.notConfigured }
        let key = Self.cacheKey(for: baseURL)
        if let cached = Self.cachedModelInfos(forKey: key) {
            return cached
        }
        guard let url = Self.modelsURL(for: baseURL) else { throw AIError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URLSession already normalizes transport failures into URLError.
            throw AIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw AIError.server(status: http.statusCode, body: Self.trimmedSnippet(snippet))
        }
        let infos = try Self.decodeModelInfos(from: data)
        Self.storeModelInfos(infos, forKey: key)
        return infos
    }

    /// Parses the OpenAI-compatible model list shape
    /// (`{"data":[{"id":"…", …},…]}`) and returns the entries sorted by id.
    /// Only `id` is required; `name` and `context_length` are consumed when a
    /// server (e.g. OpenRouter) publishes them and degrade to nil otherwise.
    static func decodeModelInfos(from data: Data) throws -> [AIModelInfo] {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIError.decoding("Response is not a JSON object.")
            }
            object = parsed
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.decoding("Response is not valid JSON.")
        }
        guard let dataArray = object["data"] as? [[String: Any]] else {
            throw AIError.decoding("Missing data array.")
        }
        var infos: [AIModelInfo] = []
        for item in dataArray {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            let name = item["name"] as? String
            // JSONSerialization yields an NSNumber for numeric JSON; `as? Int`
            // bridges integer NSNumber values and drops fractional/string ones.
            let contextLength = item["context_length"] as? Int
            infos.append(AIModelInfo(id: id, name: name, contextLength: contextLength))
        }
        return infos.sorted { $0.id < $1.id }
    }

    /// Picks the id most likely to accept a Chat Completions request, so auto
    /// discovery never lands on an embedding/rerank/speech endpoint that would
    /// reject the request. Returns the first sorted chat-capable id, preferring
    /// ids the server names with obvious chat markers.
    static func chooseChatModel(from ids: [String]) -> String? {
        let nonChatMarkers = [
            "embed", "embedding", "rerank", "whisper", "tts", "stt",
            "transcribe", "translate", "dalle", "clip", "moderation", "similarity",
        ]
        let candidates = ids.filter { id in
            let lowered = id.lowercased()
            return !nonChatMarkers.contains { lowered.contains($0) }
        }
        guard !candidates.isEmpty else { return nil }
        let chatMarked = candidates.filter { id in
            let lowered = id.lowercased()
            return lowered.contains("chat") || lowered.contains("instruct") || lowered.contains("latest")
        }
        return (chatMarked.isEmpty ? candidates : chatMarked).sorted().first
    }

    /// The id chat requests should carry: the explicit override when one is
    /// set, otherwise the best chat-capable id discovered from the server.
    /// Never hardcoded — an empty override always consults the endpoint.
    func resolveModel() async throws -> String {
        if !model.isEmpty {
            return model
        }
        let infos = try await listModelInfos()
        let ids = infos.map(\.id)
        guard let chosen = Self.chooseChatModel(from: ids) else {
            throw AIError.unsupported(
                "Could not identify a chat model — set one in Settings → AI.")
        }
        return chosen
    }

    /// The window the server itself declared for the in-use model, when the
    /// discovery cache knows it. Multi-model gateways (e.g. OpenRouter) publish
    /// `context_length` per model in `GET /v1/models`, so once Settings has
    /// fetched that list the app sizes requests to the real window instead of
    /// the manual setting. Consults the discovery cache only — never blocks a
    /// request on the network — and falls back to `AIConfig.maxContextTokens`
    /// when the list isn't cached, the model isn't listed, the server declares
    /// no window, or the value is out of the pipeline's safe range.
    func contextTokenLimit() async -> Int? {
        guard !baseURL.isEmpty else { return AIConfig.maxContextTokens }
        guard let infos = Self.cachedModelInfos(forKey: Self.cacheKey(for: baseURL)) else {
            return AIConfig.maxContextTokens
        }
        let target: AIModelInfo?
        if !model.isEmpty {
            target = infos.first { $0.id == model }
        } else {
            let ids = infos.map(\.id)
            guard let chosen = Self.chooseChatModel(from: ids) else {
                return AIConfig.maxContextTokens
            }
            target = infos.first { $0.id == chosen }
        }
        guard let length = target?.contextLength,
              length >= AIConfig.minContextTokens else {
            return AIConfig.maxContextTokens
        }
        return min(length, AIConfig.maxContextTokensCeiling)
    }

    func generate(_ prompt: AIPrompt) async throws -> AIGeneration {
        guard prompt.images.isEmpty else {
            throw AIError.unsupported("Image input is not available yet.")
        }
        guard let url = Self.chatCompletionsURL(for: baseURL) else {
            throw AIError.notConfigured
        }

        // Decide the model up front (pinned override, or the auto-selected
        // server id) and record it so logs can show exactly what was sent.
        let resolvedModel = try await resolveModel()
        Self.recordResolvedModel(resolvedModel)

        let request = try makeRequest(url: url, prompt: prompt, model: resolvedModel)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URLSession already normalizes transport failures into URLError.
            throw AIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            let trimmed = Self.trimmedSnippet(snippet)
            if Self.isContextOverflowBody(snippet) {
                throw AIError.contextSizeExceeded(limit: AIConfig.maxContextTokens)
            }
            throw AIError.server(status: http.statusCode, body: trimmed)
        }

        return try Self.decodeMessage(from: data)
    }

    // MARK: - Request building

    /// Normalizes a user-typed base URL into a chat-completions endpoint:
    /// - already `…/chat/completions` → used as-is
    /// - already ends in `/v1` → `…/v1/chat/completions`
    /// - anything else → `…/v1/chat/completions`
    static func chatCompletionsURL(for baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard !base.isEmpty else { return nil }

        if base.hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        let prefix = base.hasSuffix("/v1") ? base : "\(base)/v1"
        return URL(string: "\(prefix)/chat/completions")
    }

    private func makeRequest(url: URL, prompt: AIPrompt, model: String) throws -> URLRequest {
        var messages: [[String: String]] = []
        if let system = prompt.system {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt.user])

        // Generous output budget: reasoning/thinking models consume part of the
        // budget for chain-of-thought, and genre/shelf requests ask for long
        // JSON. A small cap (1024) let thinking eat the whole budget, so the
        // server returned `content` empty and every AI-assisted genre feature
        // failed with "Missing text content in message."
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 8192,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local endpoints often need no API key — skip the (empty) header
        // rather than sending a useless `Authorization: Bearer `.
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Whether a server error body describes a context-window overflow
    /// (OpenAI and most compatible servers phrase it around "context length" /
    /// "context size" / "maximum tokens"). Returns true so `generate` can map
    /// it to a precise `contextSizeExceeded` error before the generic server
    /// branch.
    static func isContextOverflowBody(_ body: String) -> Bool {
        let text = body.lowercased()
        return text.contains("context")
            && (text.contains("length") || text.contains("size") || text.contains("exceed") || text.contains("token"))
    }

    /// Pulls `choices[0].message.content` (and the model's chain-of-thought,
    /// when the server exposes it) out of a non-streaming response, or throws
    /// `.decoding` when the shape is wrong. Content and reasoning are kept
    /// separate so callers can surface what the model was thinking.
    static func decodeMessage(from data: Data) throws -> AIGeneration {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIError.decoding("Response is not a JSON object.")
            }
            object = parsed
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.decoding("Response is not valid JSON.")
        }

        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            throw AIError.decoding("Missing choices.")
        }
        guard let message = first["message"] as? [String: Any] else {
            throw AIError.decoding("Missing message in first choice.")
        }
        // Accept the standard string form, and the content-part array form
        // (`[{"type":"text","text":…}, …]`) some OpenAI-compatible servers
        // return. A missing string content with only `reasoning`/CoT present is
        // surfaced as a precise error instead of "Missing text content".
        if let text = message["content"] as? String, !text.isEmpty {
            return AIGeneration(text: text, reasoning: extractReasoning(message))
        }
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                guard let text = part["text"] as? String, !text.isEmpty else { return nil }
                return text
            }.joined(separator: "\n")
            if !joined.isEmpty {
                return AIGeneration(text: joined, reasoning: extractReasoning(message))
            }
        }
        if let reasoning = extractReasoning(message), !reasoning.isEmpty {
            // Only chain-of-thought came back (output budget exhausted); use it
            // as the best available answer text and still surface it as
            // reasoning.
            return AIGeneration(text: reasoning, reasoning: reasoning)
        }
        throw AIError.decoding(
            "The model returned no visible text response — it likely ran out of output tokens. Retry and check Settings → AI.")
    }

    /// The chain-of-thought the server attached to the message, if any
    /// (`reasoning` on some self-hosted reasoning models, `reasoning_content`
    /// on others).
    private static func extractReasoning(_ message: [String: Any]) -> String? {
        for key in ["reasoning", "reasoning_content"] {
            if let value = message[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func trimmedSnippet(_ body: String) -> String {
        // Keep error bodies digestible in both the UI and logs.
        let cleaned = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let limit = 200
        return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit)) + "…"
    }
}
