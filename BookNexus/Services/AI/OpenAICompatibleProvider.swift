import Foundation

/// An OpenAI-compatible chat-completions provider (works against api.openai.com
/// or any self-hosted /v1 API that mirrors the chat-completions shape).
///
/// The transport (`URLSession`) is injectable so tests can substitute a mock
/// `URLProtocol` and never touch the network.
final class OpenAICompatibleProvider: AIModelProviding {

    static var engine: AIEngine { .openAI }
    var engine: AIEngine { .openAI }

    private let baseURL: String
    private let apiKey: String
    private let session: URLSession
    private let model: String

    init(baseURL: String, apiKey: String, model: String = "gpt-4o-mini", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func availability() async -> AIAvailability {
        guard !baseURL.isEmpty, !apiKey.isEmpty else {
            return .unavailable("Missing base URL or API key.")
        }
        return .available
    }

    func generate(_ prompt: AIPrompt) async throws -> String {
        guard prompt.images.isEmpty else {
            throw AIError.unsupported("Image input is not available yet.")
        }
        guard let url = Self.chatCompletionsURL(for: baseURL) else {
            throw AIError.notConfigured
        }

        let request = try makeRequest(url: url, prompt: prompt)
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

    private func makeRequest(url: URL, prompt: AIPrompt) throws -> URLRequest {
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
