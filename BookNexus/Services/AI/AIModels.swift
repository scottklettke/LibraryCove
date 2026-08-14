import Foundation

/// Backends the app can route inference through. Only `.openAI` (an
/// OpenAI-compatible endpoint, base URL + API key) works today; on-device and
/// Private Cloud Compute arrive with the iOS 27 SDK upgrade and will be added
/// as cases here when that toolchain is available.
enum AIEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case onDevice
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice:
            return "On-device (Apple Intelligence)"
        case .openAI:
            return "OpenAI"
        }
    }

    /// Whether this engine is available with the installed SDK. On-device
    /// (FoundationModels text) works now; Private Cloud Compute + multimodal
    /// need the newer SDK wave and are added later.
    var isAvailableNow: Bool {
        switch self {
        case .onDevice, .openAI:
            return true
        }
    }
}

/// Result of probing whether inference can run right now.
enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(String) // explains why (not configured, error, etc.)
}

/// A single request to an inference provider.
struct AIPrompt: Sendable {
    var system: String?
    var user: String
    var images: [Data] = []

    init(system: String? = nil, user: String, images: [Data] = []) {
        self.system = system
        self.user = user
        self.images = images
    }
}

/// The seam every engine implements. `engine` is exposed as both an instance
/// and a static so callers can discover capabilities without an instance when
/// convenient; `availability()` lets UI reflect readiness before generating.
protocol AIModelProviding {
    var engine: AIEngine { get }
    static var engine: AIEngine { get }
    func availability() async -> AIAvailability
    func generate(_ prompt: AIPrompt) async throws -> String
}

/// Errors surfaced by the AI layer. Localized so SwiftUI can present them
/// directly.
enum AIError: LocalizedError {
    /// No endpoint or key is configured (or the selected engine can't run yet).
    case notConfigured
    /// The engine is chosen but can't run right now (e.g. Apple
    /// Intelligence off, model assets still downloading).
    case engineUnavailable(String)
    /// Transport-level failure reaching the endpoint.
    case network(Error)
    /// The endpoint answered with a non-2xx status and an optional body
    /// snippet for the user/developer.
    case server(status: Int, body: String)
    /// The response body couldn't be parsed into a completion string.
    case decoding(String)
    /// The request is valid but this engine can't handle it yet.
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No AI endpoint is configured. Set your endpoint and API key in Settings."
        case .engineUnavailable(let reason):
            return reason
        case .network(let error):
            return "Could not reach the AI endpoint: \(error.localizedDescription)"
        case .server(let status, let body):
            if body.isEmpty {
                return "The AI endpoint returned an error (HTTP \(status))."
            }
            return "The AI endpoint returned an error (HTTP \(status)): \(body)"
        case .decoding(let detail):
            if detail.isEmpty {
                return "The AI endpoint returned an unexpected response."
            }
            return "The AI endpoint returned an unexpected response: \(detail)"
        case .unsupported(let reason):
            return "Not supported: \(reason)"
        }
    }
}
