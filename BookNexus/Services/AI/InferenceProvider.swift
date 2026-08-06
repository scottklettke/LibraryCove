import Foundation

/// Chat message exchanged with a model.
struct ChatMessage: Sendable, Equatable {
    let role: ChatRole
    let content: String
}

enum ChatRole: String, Sendable {
    case system
    case user
    case assistant
}

/// An inference provider: either a locally installed model (via QVAC/llama)
/// or any OpenAI-compatible endpoint typed in by the user.
protocol InferenceProvider: AnyObject, Sendable {
    func complete(messages: [ChatMessage]) async throws -> String
}

/// Local on-device inference. QVAC integration is planned; this stub
/// documents the seam so the model manager can be plugged in.
final class LocalModelProvider: InferenceProvider {
    private let modelID: String

    init(modelID: String) {
        self.modelID = modelID
    }

    func complete(messages: [ChatMessage]) async throws -> String {
        // TODO: route to QVAC/llama.cpp native bindings
        return ""
    }
}

/// OpenAI-compatible endpoint provider. The user types base URL + model + key.
final class EndpointProvider: InferenceProvider {
    private let baseURL: URL
    private let model: String
    private let apiKey: String?

    init(baseURL: URL, model: String, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    func complete(messages: [ChatMessage]) async throws -> String {
        // TODO: POST {base}/chat/completions (streaming SSE)
        return ""
    }
}
