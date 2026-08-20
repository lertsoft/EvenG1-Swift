import Foundation

enum AppleAssistantAvailability: Equatable {
    case available
    case requiresIOS26
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case unavailable

    var message: String {
        switch self {
        case .available:
            return "Apple Intelligence ready"
        case .requiresIOS26:
            return "General answers require iOS 26 and Apple Intelligence."
        case .deviceNotEligible:
            return "This iPhone does not support Apple Intelligence."
        case .appleIntelligenceDisabled:
            return "Turn on Apple Intelligence in Settings to use general answers."
        case .modelNotReady:
            return "The Apple Intelligence model is still downloading."
        case .unavailable:
            return "Apple Intelligence is currently unavailable."
        }
    }
}

enum AppleIntelligenceAssistant {
    static func availability() -> AppleAssistantAvailability {
        guard #available(iOS 26.0, *) else { return .requiresIOS26 }
        return availabilityOnIOS26()
    }

    static func answer(_ prompt: String) async throws -> String {
        guard #available(iOS 26.0, *) else {
            return AppleAssistantAvailability.requiresIOS26.message
        }
        return try await answerOnIOS26(prompt)
    }
}

@available(iOS 26.0, *)
private extension AppleIntelligenceAssistant {
    static func availabilityOnIOS26() -> AppleAssistantAvailability {
        importFoundationModelsAvailability()
    }

    static func answerOnIOS26(_ prompt: String) async throws -> String {
        try await FoundationModelBridge.answer(prompt)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
private func importFoundationModelsAvailability() -> AppleAssistantAvailability {
    switch SystemLanguageModel.default.availability {
    case .available:
        return .available
    case .unavailable(.deviceNotEligible):
        return .deviceNotEligible
    case .unavailable(.appleIntelligenceNotEnabled):
        return .appleIntelligenceDisabled
    case .unavailable(.modelNotReady):
        return .modelNotReady
    @unknown default:
        return .unavailable
    }
}

@available(iOS 26.0, *)
private enum FoundationModelBridge {
    static func answer(_ prompt: String) async throws -> String {
        guard importFoundationModelsAvailability() == .available else {
            return importFoundationModelsAvailability().message
        }
        let session = LanguageModelSession(instructions: """
        You are the concise voice assistant for EvenG1 smart glasses. Answer in plain text. \
        Put the most useful information first. Use at most 55 words because the answer is shown \
        on a small heads-up display. Never claim to be Siri and never invent live information.
        """)
        return try await session.respond(to: prompt).content
    }
}
#else
@available(iOS 26.0, *)
private func importFoundationModelsAvailability() -> AppleAssistantAvailability { .unavailable }
#endif
