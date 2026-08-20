import Testing
import Foundation
@testable import BookNexus

/// Stubs every URLSession load so provider tests never touch the network.
/// The single static `handler` is fine because the suite is `.serialized`.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            fatalError("MockURLProtocol.handler must be set before use")
        }
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

@Suite(.serialized) struct AITests {

    // MARK: - Helpers

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func provider(session: URLSession) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "test-key",
            session: session
        )
    }

    /// Auto-discovery caches per endpoint, and the suite is `.serialized` — a
    /// plain static dictionary would silently leak one test's model list into
    /// the next. Every test that routes a models probe flushes first so the
    /// mock handler actually runs and the assertion is deterministic.
    private static func resetDiscovery() {
        OpenAICompatibleProvider.flushModelCache()
    }

    /// True when the request targets the model-list endpoint. Discovery and
    /// chat traverse the same static `handler`; tests switch on this so the
    /// mock never answers a chat request with a models payload (or vice versa).
    private static func isModelsRequest(_ request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/models") == true
    }

    /// A fake `GET {base}/v1/models` response carrying `ids`.
    private static func modelsResponse(_ request: URLRequest, ids: [String]) -> (HTTPURLResponse, Data) {
        let data = ids.map { ["id": $0, "object": "model"] }
        let body: [String: Any] = ["object": "list", "data": data]
        let json = try! JSONSerialization.data(withJSONObject: body)
        return AITests.jsonResponse(request, status: 200, body: String(data: json, encoding: .utf8)!)
    }

    /// A fake `GET {base}/v1/models` response carrying rich `AIModelInfo`
    /// entries (optional name and context window), like OpenRouter provides.
    private static func modelsResponse(_ request: URLRequest, infos: [AIModelInfo]) -> (HTTPURLResponse, Data) {
        let data = infos.map { info -> [String: Any] in
            var item: [String: Any] = ["id": info.id, "object": "model"]
            if let name = info.name { item["name"] = name }
            if let contextLength = info.contextLength { item["context_length"] = contextLength }
            return item
        }
        let body: [String: Any] = ["object": "list", "data": data]
        let json = try! JSONSerialization.data(withJSONObject: body)
        return AITests.jsonResponse(request, status: 200, body: String(data: json, encoding: .utf8)!)
    }

    private static func jsonResponse(_ request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    /// Reads the body of a captured request. URLSession hands URLProtocol a
    /// request whose body lives on `httpBodyStream` (not `httpBody`), so read
    /// whichever is populated.
    private static func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        if let httpBody = request.httpBody {
            return try parseBody(data: httpBody)
        }
        guard let stream = request.httpBodyStream else {
            throw URLError(.cannotParseResponse)
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return try parseBody(data: data)
    }

    private static func parseBody(data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: - Provider: success path

    @Test func generateParsesContentAndBuildsCorrectRequest() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            // Auto-discovery: the models endpoint is consulted first, and the
            // chat request then carries the id the server reported.
            if AITests.isModelsRequest(request) {
                // Includes an embedding id the chat heuristic must skip.
                return AITests.modelsResponse(request, ids: ["text-embedding-3-small", "gpt-4o-2024-11-20"])
            }
            #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.allHTTPHeaderFields?["Content-Type"] == "application/json")
            #expect(request.allHTTPHeaderFields?["Authorization"] == "Bearer test-key")

            let body = try AITests.bodyObject(request)
            // Not the old hardcoded gpt-4o-mini: it's the chat-capable id the
            // server list actually contained.
            #expect(body["model"] as? String == "gpt-4o-2024-11-20")
            #expect(body["max_tokens"] as? Int == 1024)
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages.count == 1)
            #expect(messages[0]["role"] == "user")
            #expect(messages[0]["content"] == "Hello there")

            let json = #"{"choices":[{"message":{"content":"Hello, world!"}}]}"#
            return AITests.jsonResponse(request, status: 200, body: json)
        }

        let result = try await AITests.provider(session: AITests.session())
            .generate(AIPrompt(user: "Hello there"))
        #expect(result == "Hello, world!")
    }

    @Test func systemMessageIncludedOnlyWhenPresent() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            let body = try AITests.bodyObject(request)
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages.count == 2)
            #expect(messages[0]["role"] == "system")
            #expect(messages[0]["content"] == "You are a helpful assistant.")
            #expect(messages[1]["role"] == "user")
            #expect(messages[1]["content"] == "Summarize this")

            let json = #"{"choices":[{"message":{"content":"done"}}]}"#
            return AITests.jsonResponse(request, status: 200, body: json)
        }

        let prompt = AIPrompt(system: "You are a helpful assistant.", user: "Summarize this")
        #expect(try await AITests.provider(session: AITests.session()).generate(prompt) == "done")
    }

    @Test func customModelFlowsThrough() async throws {
        MockURLProtocol.handler = { request in
            let body = try AITests.bodyObject(request)
            #expect(body["model"] as? String == "custom-model")
            return AITests.jsonResponse(request, status: 200, body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        }
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "test-key",
            model: "custom-model",
            session: AITests.session()
        )
        #expect(try await provider.generate(AIPrompt(user: "x")) == "ok")
    }

    // MARK: - Provider: error paths

    @Test func non2xxThrowsServerErrorWithBodySnippet() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                // Discovery succeeds; the failure we're testing is on the chat
                // call itself.
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            let body = #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#
            return AITests.jsonResponse(request, status: 401, body: body)
        }

        do {
            _ = try await AITests.provider(session: AITests.session()).generate(AIPrompt(user: "x"))
            Issue.record("Expected a server error")
        } catch AIError.server(let status, let errorBody) {
            #expect(status == 401)
            #expect(errorBody.contains("Incorrect API key"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func serverErrorWithoutBodyUsesEmptySnippet() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            return AITests.jsonResponse(request, status: 500, body: "   \n  ")
        }

        do {
            _ = try await AITests.provider(session: AITests.session()).generate(AIPrompt(user: "x"))
            Issue.record("Expected a server error")
        } catch AIError.server(let status, let errorBody) {
            #expect(status == 500)
            #expect(errorBody.isEmpty)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func malformedResponseThrowsDecoding() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            return AITests.jsonResponse(request, status: 200, body: #"{}"#)
        }
        do {
            _ = try await AITests.provider(session: AITests.session()).generate(AIPrompt(user: "x"))
            Issue.record("Expected a decoding error")
        } catch AIError.decoding {
            // Expected: missing choices.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func invalidJSONThrowsDecoding() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            return AITests.jsonResponse(request, status: 200, body: "not json at all")
        }
        do {
            _ = try await AITests.provider(session: AITests.session()).generate(AIPrompt(user: "x"))
            Issue.record("Expected a decoding error")
        } catch AIError.decoding {
            // Expected: response is not valid JSON.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func transportFailureThrowsNetworkError() async throws {
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await AITests.provider(session: AITests.session()).generate(AIPrompt(user: "x"))
            Issue.record("Expected a network error")
        } catch AIError.network {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func imagesRejectedAsUnsupportedBeforeAnyNetworkCall() async throws {
        var networkCalled = false
        MockURLProtocol.handler = { request in
            networkCalled = true
            return AITests.jsonResponse(request, status: 200, body: #"{"choices":[{"message":{"content":"x"}}]}"#)
        }

        let prompt = AIPrompt(user: "Look at this", images: [Data("fake".utf8)])
        do {
            _ = try await AITests.provider(session: AITests.session()).generate(prompt)
            Issue.record("Expected unsupported error")
        } catch AIError.unsupported {
            #expect(!networkCalled)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Provider: base URL normalization

    @Test func normalizesBaseURLVariants() {
        #expect(OpenAICompatibleProvider.chatCompletionsURL(for: "https://api.example.com")?.absoluteString
            == "https://api.example.com/v1/chat/completions")
        #expect(OpenAICompatibleProvider.chatCompletionsURL(for: "https://api.example.com/v1")?.absoluteString
            == "https://api.example.com/v1/chat/completions")
        #expect(OpenAICompatibleProvider.chatCompletionsURL(for: "https://api.example.com/v1/")?.absoluteString
            == "https://api.example.com/v1/chat/completions")
        #expect(OpenAICompatibleProvider.chatCompletionsURL(for: "https://api.example.com/chat/completions")?.absoluteString
            == "https://api.example.com/chat/completions")
        #expect(OpenAICompatibleProvider.chatCompletionsURL(for: "") == nil)
        #expect(OpenAICompatibleProvider.chatCompletionsURL(for: "   ") == nil)
    }

    @Test func bareBaseURLStillHitsV1Endpoint() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                #expect(request.url?.absoluteString == "https://api.example.com/v1/models")
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
            return AITests.jsonResponse(request, status: 200, body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        }
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com",
            apiKey: "test-key",
            session: AITests.session()
        )
        #expect(try await provider.generate(AIPrompt(user: "x")) == "ok")
    }

    @Test func normalizesModelsURLVariants() {
        #expect(OpenAICompatibleProvider.modelsURL(for: "https://api.example.com")?.absoluteString
            == "https://api.example.com/v1/models")
        #expect(OpenAICompatibleProvider.modelsURL(for: "https://api.example.com/v1")?.absoluteString
            == "https://api.example.com/v1/models")
        #expect(OpenAICompatibleProvider.modelsURL(for: "https://api.example.com/v1/")?.absoluteString
            == "https://api.example.com/v1/models")
        #expect(OpenAICompatibleProvider.modelsURL(for: "https://api.example.com/v1/models")?.absoluteString
            == "https://api.example.com/v1/models")
        #expect(OpenAICompatibleProvider.modelsURL(for: "https://api.example.com/models")?.absoluteString
            == "https://api.example.com/models")
        #expect(OpenAICompatibleProvider.modelsURL(for: "") == nil)
        #expect(OpenAICompatibleProvider.modelsURL(for: "   ") == nil)
    }

    // The whole point of model discovery: never a hardcoded id. When the list
    // contains nothing chat-capable, request a manual pin instead of guessing.
    @Test func autoDiscoveryRejectsAllNonChatModelsWithGuidance() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            AITests.modelsResponse(request, ids: ["text-embedding-3-small", "rerank-english-v3", "whisper-1"])
        }
        do {
            _ = try await AITests.provider(session: AITests.session()).generate(AIPrompt(user: "x"))
            Issue.record("Expected an unsupported error")
        } catch AIError.unsupported(let reason) {
            #expect(reason.contains("set one in Settings"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // A pinned model is sent verbatim and discovery never runs (no models
    // probe, first request is the chat call itself).
    @Test func modelOverrideSkipsDiscoveryAndSendsOverride() async throws {
        AITests.resetDiscovery()
        var chatRequestSeen = false
        MockURLProtocol.handler = { request in
            #expect(!AITests.isModelsRequest(request),
                    "override must skip the models probe")
            chatRequestSeen = true
            let body = try AITests.bodyObject(request)
            #expect(body["model"] as? String == "custom-model")
            return AITests.jsonResponse(request, status: 200, body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        }
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "test-key",
            model: "custom-model",
            session: AITests.session()
        )
        let text = try await provider.generate(AIPrompt(user: "x"))
        #expect(text == "ok")
        #expect(chatRequestSeen)
        // The resolved model is recorded so the request log can show what was
        // actually sent — visibility requirement, not just internals.
        #expect(OpenAICompatibleProvider.lastResolvedModel == "custom-model")
    }

    // The resolved (auto-discovered) model is exposed so logs/UI can show the
    // user what the server actually said to use.
    @Test func autoDiscoveryRecordsResolvedModelForVisibility() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                return AITests.modelsResponse(request, ids: ["text-embedding-3-small", "gpt-4o-2024-11-20"])
            }
            return AITests.jsonResponse(request, status: 200, body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        }
        _ = try await AITests.provider(session: AITests.session()).generate(AIPrompt(user: "x"))
        // NOT gpt-4o-mini — the server-reported chat id, proving discovery ran.
        #expect(OpenAICompatibleProvider.lastResolvedModel == "gpt-4o-2024-11-20")
    }

    // MARK: - AIService + AIConfig integration

    // MARK: - Provider: model metadata + server-declared context

    @Test func decodeModelInfosReadsOptionalMetadata() throws {
        let json = #"{"data":[{"id":"openai/gpt-4o-mini","name":"OpenAI: GPT-4o-mini","context_length":128000},{"id":"ollama/qwen","object":"model"},{"id":"legacy","context_length":"4096"}]}"#
        let infos = try OpenAICompatibleProvider.decodeModelInfos(from: Data(json.utf8))

        let named = infos.first { $0.id == "openai/gpt-4o-mini" }
        #expect(named?.name == "OpenAI: GPT-4o-mini")
        #expect(named?.contextLength == 128000)

        // Plain id-only entries (API-key OpenAI, most local servers) parse fine.
        let plain = infos.first { $0.id == "ollama/qwen" }
        #expect(plain?.name == nil)
        #expect(plain?.contextLength == nil)

        // A string context_length degrades to nil rather than failing the parse.
        let stringCtx = infos.first { $0.id == "legacy" }
        #expect(stringCtx?.contextLength == nil)
    }

    // A server that publishes context_length (OpenRouter does) lets the app
    // size requests to the real window once Settings has loaded the model list.
    @Test func contextLimitUsesServerDeclaredWindowForPinnedModel() async throws {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AIConfig.maxContextTokens = 4096
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            AITests.modelsResponse(request, infos: [
                AIModelInfo(id: "text-embedding-3-small", name: "Embeddings", contextLength: 9000),
                AIModelInfo(id: "openai/gpt-4o-mini", name: "OpenAI: GPT-4o-mini", contextLength: 128000),
            ])
        }
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "test-key",
            model: "openai/gpt-4o-mini",
            session: AITests.session()
        )
        // Warm the discovery cache exactly as Settings does at connection time.
        _ = try await provider.listModelInfos()
        #expect(await provider.contextTokenLimit() == 128000)
    }

    @Test func contextLimitTracksAutoSelectedModelWhenUnpinned() async throws {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AIConfig.maxContextTokens = 2048
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            AITests.modelsResponse(request, infos: [
                AIModelInfo(id: "text-embedding-3-small", name: nil, contextLength: 9000),
                AIModelInfo(id: "openai/gpt-4o-mini", name: "OpenAI: GPT-4o-mini", contextLength: 128000),
            ])
        }
        // Unpinned: the auto-selected chat model's window applies, not the
        // embedding model's.
        let provider = AITests.provider(session: AITests.session())
        _ = try await provider.listModelInfos()
        #expect(await provider.contextTokenLimit() == 128000)
    }

    @Test func contextLimitClampsHugeDeclaredWindowToPipelineCeiling() async throws {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AIConfig.maxContextTokens = 4096
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            AITests.modelsResponse(request, infos: [
                AIModelInfo(id: "anthropic/claude-sonnet-4.5", name: "Anthropic: Claude Sonnet 4.5", contextLength: 2_000_000),
            ])
        }
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "test-key",
            model: "anthropic/claude-sonnet-4.5",
            session: AITests.session()
        )
        _ = try await provider.listModelInfos()
        #expect(await provider.contextTokenLimit() == AIConfig.maxContextTokensCeiling)
    }

    @Test func contextLimitFallsBackToConfiguredWhenServerDeclaresNoWindow() async throws {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AIConfig.maxContextTokens = 8192
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            // Plain id-only entries — API-key OpenAI and local servers report
            // no window, so the manual setting governs.
            AITests.modelsResponse(request, ids: ["gpt-4o"])
        }
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "test-key",
            model: "gpt-4o",
            session: AITests.session()
        )
        _ = try await provider.listModelInfos()
        #expect(await provider.contextTokenLimit() == 8192)
    }

    @Test func contextLimitColdCacheFallsBackToConfiguredWithoutNetwork() async throws {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AIConfig.maxContextTokens = 4096
        AITests.resetDiscovery()
        // Never warms the cache, so contextTokenLimit must not touch the
        // network — the mock handler would fail the test if it ran.
        MockURLProtocol.handler = { _ in
            Issue.record("contextTokenLimit must not fetch on a cold cache")
            return AITests.jsonResponse(URLRequest(url: URL(string: "https://api.example.com")!),
                                        status: 200, body: "{}")
        }
        let provider = AITests.provider(session: AITests.session())
        #expect(await provider.contextTokenLimit() == 4096)
    }

    // MARK: - Provider: context-window overflow

    @Test func isContextOverflowBodyHeuristic() {
        #expect(OpenAICompatibleProvider.isContextOverflowBody(
            "This model's maximum context length is 4096 tokens"))
        #expect(OpenAICompatibleProvider.isContextOverflowBody(
            #"{"error":{"message":"maximum context size exceeded"}}"#))
        #expect(!OpenAICompatibleProvider.isContextOverflowBody(
            "Incorrect API key provided"))
        #expect(!OpenAICompatibleProvider.isContextOverflowBody(""))
    }

    @Test func contextLengthBodyMapsToContextSizeExceeded() async throws {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AITests.resetDiscovery()

        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            return AITests.jsonResponse(request, status: 400,
                body: #"{"error":{"message":"This model's maximum context length is 4096 tokens","type":"invalid_request_error"}}"#)
        }
        let provider = AITests.provider(session: AITests.session())
        do {
            _ = try await provider.generate(AIPrompt(user: "hi"))
            Issue.record("expected a contextSizeExceeded error")
        } catch let error as AIError {
            guard case .contextSizeExceeded = error else {
                Issue.record("wrong error surfaced: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func nonContextServerBodyStaysServerError() async throws {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AITests.resetDiscovery()

        MockURLProtocol.handler = { request in
            if AITests.isModelsRequest(request) {
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            return AITests.jsonResponse(request, status: 401,
                body: #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#)
        }
        let provider = AITests.provider(session: AITests.session())
        do {
            _ = try await provider.generate(AIPrompt(user: "hi"))
            Issue.record("expected an error")
        } catch let error as AIError {
            guard case .server = error else {
                Issue.record("wrong error surfaced: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - OpenAI endpoint setup

    // API keys are optional for OpenAI-compatible endpoints (local servers
    // like Ollama/lm-studio usually need none), so an empty key must not block
    // a configured endpoint.
    @Test func keylessEndpointIsConsideredConfigured() async {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        AIConfig.selectedEngine = .openAI
        AIConfig.openAIBaseURL = "http://127.0.0.1:11434/v1"
        AIConfig.openAIAPIKey = "" // ensure empty

        let availability = await AIService.shared.availability()
        #expect(availability == .available)
        #expect(AIConfig.isOpenAIConfigured)
    }

    @Test func requestWithoutAPIKeySucceedsAndOmitsAuthHeader() async throws {
        AITests.resetDiscovery()
        MockURLProtocol.handler = { request in
            // Empty key → no Authorization header at all (not an empty bearer),
            // on either the models probe or the chat call.
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if AITests.isModelsRequest(request) {
                return AITests.modelsResponse(request, ids: ["gpt-4o"])
            }
            return AITests.jsonResponse(request, status: 200,
                body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        }
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "",
            session: AITests.session()
        )
        let text = try await provider.generate(AIPrompt(user: "hi"))
        #expect(text == "ok")
    }

    @Test func emptyBaseURLThroughAIServiceThrowsNotConfigured() async throws {
        AIConfig.resetForTesting()
        AIConfig.selectedEngine = .openAI
        AIConfig.openAIAPIKey = "test-key"
        AIConfig.openAIBaseURL = ""

        do {
            _ = try await AIService.shared.generate(AIPrompt(user: "x"))
            Issue.record("Expected notConfigured")
        } catch AIError.notConfigured {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func availabilityMirrorsConfiguration() async {
        AIConfig.resetForTesting()
        AIConfig.selectedEngine = .openAI
        AIConfig.openAIAPIKey = ""
        AIConfig.openAIBaseURL = ""
        #expect(await AIService.shared.availability() == .unavailable("Missing base URL."))

        // A key is optional: a base URL alone makes the endpoint available.
        AIConfig.openAIAPIKey = ""
        AIConfig.openAIBaseURL = "http://127.0.0.1:11434/v1"
        #expect(await AIService.shared.availability() == .available)

        AIConfig.openAIAPIKey = "test-key"
        #expect(await AIService.shared.availability() == .available)
    }

    @Test func enginePersistenceRoundTrip() {
        AIConfig.resetForTesting()
        #expect(AIConfig.selectedEngine == .openAI) // default

        AIConfig.selectedEngine = .openAI
        #expect(AIConfig.selectedEngine == .openAI)
    }

    @Test func engineFallsBackToDefaultForUnknownRawValue() {
        AIConfig.resetForTesting()
        UserDefaults.standard.set("quantum", forKey: "AI.selectedEngine")
        #expect(AIConfig.selectedEngine == .openAI)
        AIConfig.resetForTesting()
    }

    @Test func baseURLFallsBackToDefaultWhenUnset() {
        AIConfig.resetForTesting()
        #expect(AIConfig.openAIBaseURL == AIConfig.defaultOpenAIBaseURL)
    }

    @Test func modelOverrideFallsBackToAutoWhenUnset() {
        AIConfig.resetForTesting()
        defer { AIConfig.resetForTesting() }
        #expect(AIConfig.openAIModel == "") // default is auto-detect

        AIConfig.openAIModel = "gpt-4o"
        #expect(AIConfig.openAIModel == "gpt-4o")
        #expect(AIConfig.openAIModel == "gpt-4o") // persisted round-trip

        AIConfig.openAIModel = "   "
        #expect(AIConfig.openAIModel == "") // whitespace trims back to auto
    }

    @Test func apiKeyRoundTripsThroughKeychain() {
        AIConfig.resetForTesting()
        AIConfig.openAIAPIKey = "sk-super-secret"
        #expect(AIConfig.openAIAPIKey == "sk-super-secret")

        AIConfig.openAIAPIKey = "" // empty write deletes the entry
        #expect(AIConfig.openAIAPIKey == "")
        AIConfig.resetForTesting()
    }
}

@Suite struct AppleIntelligenceTests {

    @available(iOS 26.0, *)
    @Test func availabilityMappingCoversReasons() {
        #expect(AppleIntelligenceProvider.map(.available) == .available)
        #expect(AppleIntelligenceProvider.map(.unavailable(.deviceNotEligible)) ==
                .unavailable("This device doesn't support Apple Intelligence."))
        #expect(AppleIntelligenceProvider.map(.unavailable(.appleIntelligenceNotEnabled)) ==
                .unavailable("Apple Intelligence is turned off. Enable it in Settings on this device."))
        #expect(AppleIntelligenceProvider.map(.unavailable(.modelNotReady)) ==
                .unavailable("The on-device model is still preparing. Try again shortly."))
    }

    @Test func enginesExposeOnDeviceAndOpenAI() {
        #expect(AIEngine.allCases.contains(.onDevice))
        #expect(AIEngine.allCases.contains(.openAI))
        #expect(AIEngine.onDevice.isAvailableNow)
        #expect(AIEngine.openAI.isAvailableNow)
    }

    @available(iOS 26.0, *)
    @Test func providerRejectsImagePrompts() async {
        let provider = AppleIntelligenceProvider()
        let prompt = AIPrompt(user: "describe", images: [Data([0xFF])])
        do {
            _ = try await provider.generate(prompt)
            Issue.record("expected unsupported error for image prompts")
        } catch AIError.unsupported {
            // expected — images are rejected before anything else
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
