import Foundation
import FoundationModels

/// App-facing mapping of `LanguageModelSession.GenerationError`, mirroring how
/// `IntelligenceAvailability` wraps `SystemLanguageModel.Availability` so `ReflectFeatures`
/// never needs to import FoundationModels just to render an error message.
nonisolated public enum IntelligenceError: Error, Equatable, Sendable {
    case contextWindowExceeded
    case refused
    case unsupportedLanguage
    case throttled
    case modelUnavailable
    case malformedOutput
    case cancelled
    case unknown

    /// Maps a thrown error to its app-facing case. Never captures or re-exposes the source
    /// error's text or `Context` payload — the raw model message must not reach the UI.
    public init(_ error: any Error) {
        if let alreadyMapped = error as? IntelligenceError {
            self = alreadyMapped
            return
        }
        if error is CancellationError {
            self = .cancelled
            return
        }
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            // Not a documented `GenerationError` case. Diagnosed on a host where
            // `SystemLanguageModel.default.isAvailable` reports `true` but the on-device
            // model's assets are not actually installed: every real generation request then
            // fails immediately with a raw, undocumented `NSError` classified below. Anything
            // else undocumented still falls through to `.unknown`.
            self = Self.isMissingModelAssetsError(error) ? .modelUnavailable : .unknown
            return
        }
        switch generationError {
        case .exceededContextWindowSize:
            self = .contextWindowExceeded
        case .guardrailViolation, .refusal:
            self = .refused
        case .unsupportedLanguageOrLocale:
            self = .unsupportedLanguage
        case .rateLimited, .concurrentRequests:
            self = .throttled
        case .assetsUnavailable:
            self = .modelUnavailable
        case .decodingFailure, .unsupportedGuide:
            self = .malformedOutput
        @unknown default:
            self = .unknown
        }
    }

    /// Domain of the raw `NSError` FoundationModels bridges its own internal
    /// `LanguageModelError` type to. Verified verbatim from a captured, undiagnosed failure
    /// (see `changes.md` "Fix cycle 2"): `Error Domain=FoundationModels.LanguageModelError
    /// Code=-1 ... UserInfo={NSMultipleUnderlyingErrorsKey=(...)}`. This domain alone is too
    /// broad to mean "assets missing" by itself — it wraps every undocumented internal
    /// failure — so it only counts as a match when the underlying-error chain also contains
    /// one of the two asset-specific domains below.
    private static let languageModelErrorDomain = "FoundationModels.LanguageModelError"
    /// Innermost domain observed in the same captured chain:
    /// `Error Domain=ModelManagerServices.ModelManagerError Code=1026 ...`.
    private static let modelManagerErrorDomain = "ModelManagerServices.ModelManagerError"
    /// Domain of the adjacent simulator log line captured during the same diagnosis:
    /// `Error Domain=com.apple.UnifiedAssetFramework Code=5000 "There are no underlying
    /// assets ... for asset set com.apple.modelcatalog"`.
    private static let unifiedAssetFrameworkDomain = "com.apple.UnifiedAssetFramework"

    /// Classifies the diagnosed "on-device model assets not installed" failure by walking the
    /// `NSError` underlying-error chain and matching on `domain`/`code` only — **never** on
    /// `localizedDescription` or any other string, so a future SDK's message wording cannot
    /// silently break this classification (or silently start matching an unrelated error).
    private static func isMissingModelAssetsError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == modelManagerErrorDomain || nsError.domain == unifiedAssetFrameworkDomain {
            return true
        }
        guard nsError.domain == languageModelErrorDomain else {
            return false
        }
        return underlyingErrors(of: nsError).contains { isMissingModelAssetsError($0) }
    }

    /// FoundationModels' captured chain nests both a single `NSUnderlyingErrorKey` and an
    /// `NSMultipleUnderlyingErrorsKey` array at different levels; check both so the walk
    /// reaches the innermost, asset-specific error regardless of which one carries it.
    private static func underlyingErrors(of error: NSError) -> [NSError] {
        var result: [NSError] = []
        if let multiple = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
            result.append(contentsOf: multiple.map { $0 as NSError })
        }
        if let single = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            result.append(single as NSError)
        }
        return result
    }

    /// Whether the coordinator should retry the same item.
    public var isRetryable: Bool {
        switch self {
        case .throttled, .modelUnavailable, .malformedOutput, .unknown:
            true
        case .refused, .unsupportedLanguage, .contextWindowExceeded, .cancelled:
            false
        }
    }

    /// `true` for `refused`: per the error policy, store nothing and allow retry, rather than
    /// leaving a stale insight next to text the model declined to analyze.
    public var shouldStoreNoInsight: Bool {
        self == .refused
    }
}
