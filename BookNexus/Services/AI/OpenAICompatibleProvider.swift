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

    init(baseURL: String, apiKey: String, model: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
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
        let ids: [String]
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

    private static func cachedModelList(forKey key: String) -> [String]? {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        guard let cached = modelListCache[key],
              Date().timeIntervalSince(cached.fetchedAt) < modelCacheTTL else {
            return nil
        }
        return cached.ids
    }

    private static func storeModelList(_ ids: [String], forKey key: String) {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        modelListCache[key] = CachedModelList(ids: ids, fetchedAt: Date())
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

    /// GETs `{base}/v1/models` and returns the server's model ids sorted
    /// alphabetically. Reuses the same status/decoding/network error mapping
    /// as chat so failures surface consistently. Results are cached for
    /// `modelCacheTTL` keyed on the normalized endpoint.
    func listModels() async throws -> [String] {
        guard !baseURL.isEmpty else { throw AIError.notConfigured }
        let key = Self.cacheKey(for: baseURL)
        if let cached = Self.cachedModelList(forKey: key) {
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
        let ids = try Self.decodeModelIDs(from: data)
        Self.storeModelList(ids, forKey: key)
        return ids
    }

    /// Parses the OpenAI-compatible model list shape
    /// (`{"data":[{"id":"…"},…]}`) and returns the sorted non-empty ids.
    static func decodeModelIDs(from data: Data) throws -> [String] {
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
        var ids: [String] = []
        for item in dataArray {
            if let id = item["id"] as? String, !id.isEmpty {
                ids.append(id)
            }
        }
        return ids.sorted()
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
        let ids = try await listModels()
        guard let chosen = Self.chooseChatModel(from: ids) else {
            throw AIError.unsupported(
                "Could not identify a chat model — set one in Settings → AI.")
        }
        return chosen
    }

    /// The OpenAI-compatible server's window is whatever the user configured
    /// in Settings → AI (this engine has no way to query the server for it).
    var contextTokenLimit: Int? { AIConfig.maxContextTokens }

    func generate(_ prompt: AIPrompt) async throws -> String {
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

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 1024,
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

    /// Pulls `choices[0].message.content` out of a non-streaming response,
    /// or throws `.decoding` when the shape is wrong.
    static func decodeMessage(from data: Data) throws -> String {
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
        guard let content = message["content"] as? String else {
            throw AIError.decoding("Missing text content in message.")
        }
        return content
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
