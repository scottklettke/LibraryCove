import Foundation

/// App-wide entry point for AI features. Reads the user's engine selection
/// from `AIConfig`, builds the matching provider, checks availability, then
/// generates.
struct AIService {
    static let shared = AIService()

    private init() {}

    /// Whether the currently selected engine is ready to run.
    func availability() async -> AIAvailability {
        await provider(for: AIConfig.selectedEngine).availability()
    }

    /// Generates a completion for `prompt`. Throws `.notConfigured` when the
    /// selected engine isn't ready (e.g. missing endpoint or API key); all
    /// other `AIError`s pass through untouched.
    func generate(_ prompt: AIPrompt) async throws -> String {
        let provider = provider(for: AIConfig.selectedEngine)
        switch await provider.availability() {
        case .available:
            break
        case .unavailable:
            throw AIError.notConfigured
        }
        return try await provider.generate(prompt)
    }

    private func provider(for engine: AIEngine) -> any AIModelProviding {
        switch engine {
        case .openAI:
            return OpenAICompatibleProvider(
                baseURL: AIConfig.openAIBaseURL,
                apiKey: AIConfig.openAIAPIKey
            )
        }
    }
}
