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
        // OpenAI needs credentials before we even try; the on-device provider
        // reports its own readiness with an actionable error instead.
        if AIConfig.selectedEngine == .openAI,
           case .unavailable = await provider.availability() {
            throw AIError.notConfigured
        }
        return try await provider.generate(prompt)
    }

    private func provider(for engine: AIEngine) -> any AIModelProviding {
        switch engine {
        case .onDevice:
            if #available(iOS 26.0, *) {
                return AppleIntelligenceProvider()
            } else {
                return UnavailableEngineProvider(engine: .onDevice,
                    reason: "On-device Apple Intelligence requires iOS 26 or later.")
            }
        case .openAI:
            return OpenAICompatibleProvider(
                baseURL: AIConfig.openAIBaseURL,
                apiKey: AIConfig.openAIAPIKey
            )
        }
    }
}

/// A never-ready provider for an engine that can't run on this OS version
/// (e.g. on-device Apple Intelligence below iOS 26).
private struct UnavailableEngineProvider: AIModelProviding {
    let engine: AIEngine
    static var engine: AIEngine = .onDevice
    private let reason: String

    init(engine: AIEngine = .onDevice, reason: String) {
        self.engine = engine
        self.reason = reason
    }

    func availability() async -> AIAvailability { .unavailable(reason) }
    func generate(_ prompt: AIPrompt) async throws -> String { throw AIError.engineUnavailable(reason) }
}
