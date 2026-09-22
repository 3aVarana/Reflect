import FoundationModels

/// App-facing view of whether the on-device model can be used right now.
/// Wraps `SystemLanguageModel.Availability` so features never import
/// FoundationModels just to render an availability message.
public enum IntelligenceAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable

    public static var current: IntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            .modelNotReady
        case .unavailable:
            .unavailable
        }
    }

    /// Short, user-facing explanation for the non-available states.
    public var message: String {
        switch self {
        case .available:
            "On-device intelligence is ready."
        case .deviceNotEligible:
            "This device doesn't support Apple Intelligence, so entries are saved without insights."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to get private, on-device insights."
        case .modelNotReady:
            "The on-device model is still downloading. Insights will appear once it's ready."
        case .unavailable:
            "On-device intelligence isn't available right now."
        }
    }
}
