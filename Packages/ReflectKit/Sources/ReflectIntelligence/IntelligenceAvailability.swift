import FoundationModels

/// App-facing view of whether the on-device model can be used right now.
/// Wraps `SystemLanguageModel.Availability` so features never import
/// FoundationModels just to render an availability message.
///
/// `nonisolated`: this type (and its `Equatable`/`Sendable` conformances) must be usable from
/// any isolation domain — `EnrichmentCoordinator`, an actor, reads `.current` to decide
/// whether an `.unknown` error should be retried. Without `nonisolated`, default `MainActor`
/// isolation would make even the synthesized `Equatable` conformance main-actor-isolated,
/// which cannot be used from another actor's context.
nonisolated public enum IntelligenceAvailability: Equatable, Sendable {
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

    /// `current`, snapshotted once at first access. `current` makes a synchronous
    /// FoundationModels call; a caller that would otherwise read it on every SwiftUI `body`/
    /// `init` evaluation (e.g. a view whose argument list changes on every keystroke, which
    /// re-runs `init` even though its persisted `@State` does not) should read this instead.
    /// Availability depends on device eligibility and the Apple Intelligence toggle, neither of
    /// which the app itself changes, so a one-time snapshot for the process's lifetime is
    /// correct here — this must not be used anywhere a genuinely live read is required (e.g.
    /// `ReflectRootView`'s launch-time gate, or `SettingsView`'s status row).
    public static let cachedAtLaunch: IntelligenceAvailability = current

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
