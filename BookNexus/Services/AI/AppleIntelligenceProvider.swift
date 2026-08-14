import Foundation
import FoundationModels

/// The on-device Apple Intelligence model, via the Foundation Models
/// framework (iOS 26+). Availability is checked at runtime — Apple
/// Intelligence-capable devices only — and the user-facing fallback is handled
/// by `AIService` (and, in Settings, the status line).
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct AppleIntelligenceProvider: AIModelProviding {
    let engine: AIEngine = .onDevice
    static let engine: AIEngine = .onDevice

    /// Maps the framework's availability to ours, with actionable reasons.
    static func map(_ raw: SystemLanguageModel.Availability) -> AIAvailability {
        switch raw {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This device doesn't support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Apple Intelligence is turned off. Enable it in Settings on this device.")
            case .modelNotReady:
                return .unavailable("The on-device model is still preparing. Try again shortly.")
            @unknown default:
                return .unavailable("The on-device model isn't available right now.")
            }
        @unknown default:
            return .unavailable("The on-device model isn't available right now.")
        }
    }

    func availability() async -> AIAvailability {
        Self.map(SystemLanguageModel.default.availability)
    }

    func generate(_ prompt: AIPrompt) async throws -> String {
        // Reject unsupported input before touching availability/model state.
        guard prompt.images.isEmpty else {
            throw AIError.unsupported("Image prompts need a FoundationModels-capable system that supports multimodal input; not available on this build yet.")
        }
        guard SystemLanguageModel.default.isAvailable else {
            throw AIError.engineUnavailable(availabilityText(from: SystemLanguageModel.default.availability))
        }

        // Fresh session per request. (A long-lived session per app run — with
        // conversation state — is a later optimization once features need it.)
        let session = LanguageModelSession(model: .default, tools: [], instructions: nil)
        session.prewarm()
        let response = try await session.respond(to: combinedText(for: prompt))
        return response.content
    }

    // MARK: - Helpers

    private func combinedText(for prompt: AIPrompt) -> String {
        guard let system = prompt.system else { return prompt.user }
        return system + "\n\n" + prompt.user
    }

    private func availabilityText(from availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "The on-device model is available."
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Enable it in Settings on this device."
            case .modelNotReady:
                return "The on-device model is still preparing. Try again shortly."
            @unknown default:
                return "The on-device model isn't available right now."
            }
        @unknown default:
            return "The on-device model isn't available right now."
        }
    }
}
