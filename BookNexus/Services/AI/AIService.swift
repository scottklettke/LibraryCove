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
    /// selected engine isn't ready (e.g. OpenAI-compatible with no endpoint
    /// URL); all other `AIError`s pass through untouched. Every call is
    /// recorded in the AI connection log (attempt → success/error), so the
    /// Settings logs section shows what the endpoint actually returned.
    func generate(_ prompt: AIPrompt) async throws -> String {
        let engine = AIConfig.selectedEngine
        let provider = provider(for: engine)
        let start = Date()
        AILogStore.append(AILogEntry(engine: engine, kind: .attempt, detail: Self.endpointDescription(engine)))
        do {
            // OpenAI-compatible needs an endpoint before we even try (key
            // optional); the on-device provider reports its own readiness with
            // an actionable error instead.
            if engine == .openAI,
               case .unavailable = await provider.availability() {
                throw AIError.notConfigured
            }
            let text = try await provider.generate(prompt)
            let latency = Date().timeIntervalSince(start) * 1000
            AILogStore.append(AILogEntry(engine: engine, kind: .success,
                                         detail: "Received \(text.count) characters.",
                                         latencyMs: latency))
            return text
        } catch {
            let latency = Date().timeIntervalSince(start) * 1000
            let detail = (error as? AIError)?.errorDescription ?? error.localizedDescription
            AILogStore.append(AILogEntry(engine: engine, kind: .error,
                                         detail: detail,
                                         latencyMs: latency))
            throw error
        }
    }

    /// What the log marks the request as targeting. Never includes the API key.
    private static func endpointDescription(_ engine: AIEngine) -> String {
        switch engine {
        case .openAI:
            let url = AIConfig.openAIBaseURL
            return "Endpoint: \(url.isEmpty ? "(not set)" : url)"
        case .onDevice:
            return "Apple Intelligence on-device model"
        }
    }

    /// The chosen engine's real per-request context budget in tokens, falling
    /// back to the user's configured window when the engine can't report one.
    /// Callers use this to size the snapshot and transcript precisely.
    func effectiveContextTokens() async -> Int {
        await provider(for: AIConfig.selectedEngine).contextTokenLimit ?? AIConfig.maxContextTokens
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
