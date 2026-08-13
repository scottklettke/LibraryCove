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
        MockURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.allHTTPHeaderFields?["Content-Type"] == "application/json")
            #expect(request.allHTTPHeaderFields?["Authorization"] == "Bearer test-key")

            let body = try AITests.bodyObject(request)
            #expect(body["model"] as? String == "gpt-4o-mini")
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
        MockURLProtocol.handler = { request in
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
        MockURLProtocol.handler = { request in
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
        MockURLProtocol.handler = { request in
            AITests.jsonResponse(request, status: 500, body: "   \n  ")
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
        MockURLProtocol.handler = { request in
            AITests.jsonResponse(request, status: 200, body: #"{}"#)
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
        MockURLProtocol.handler = { request in
            AITests.jsonResponse(request, status: 200, body: "not json at all")
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
        MockURLProtocol.handler = { request in
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

    // MARK: - AIService + AIConfig integration

    @Test func missingKeyThroughAIServiceThrowsNotConfigured() async throws {
        AIConfig.resetForTesting()
        AIConfig.selectedEngine = .openAI
        AIConfig.openAIBaseURL = "https://api.example.com/v1"
        AIConfig.openAIAPIKey = "" // ensure empty

        do {
            _ = try await AIService.shared.generate(AIPrompt(user: "x"))
            Issue.record("Expected notConfigured")
        } catch AIError.notConfigured {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
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
        #expect(await AIService.shared.availability() == .unavailable("Missing base URL or API key."))

        AIConfig.openAIAPIKey = "test-key"
        AIConfig.openAIBaseURL = "https://api.example.com/v1"
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

    @Test func apiKeyRoundTripsThroughKeychain() {
        AIConfig.resetForTesting()
        AIConfig.openAIAPIKey = "sk-super-secret"
        #expect(AIConfig.openAIAPIKey == "sk-super-secret")

        AIConfig.openAIAPIKey = "" // empty write deletes the entry
        #expect(AIConfig.openAIAPIKey == "")
        AIConfig.resetForTesting()
    }
}
