import Testing
import Foundation
@testable import ReflectIntelligence

// `LanguageModelSession.GenerationError`'s cases each carry a `Context` payload that is not
// constructible from outside FoundationModels (its initializer is internal to the framework),
// so the `GenerationError -> IntelligenceError` mapping in `IntelligenceError.init(_:)` cannot
// be exercised with real framework errors from a test target. Per the plan's risk #7, this
// suite instead exhaustively tests `IntelligenceError`'s own behaviour: `isRetryable`,
// `shouldStoreNoInsight`, pass-through of an already-mapped error, and mapping of
// `CancellationError` and of an arbitrary unrelated error to `.unknown`.
struct IntelligenceErrorTests {
    private struct SomeOtherError: Error {}

    @Test func isRetryableIsTrueForThrottledModelUnavailableMalformedOutputAndUnknown() {
        #expect(IntelligenceError.throttled.isRetryable)
        #expect(IntelligenceError.modelUnavailable.isRetryable)
        #expect(IntelligenceError.malformedOutput.isRetryable)
        #expect(IntelligenceError.unknown.isRetryable)
    }

    @Test func isRetryableIsFalseForRefusedUnsupportedLanguageContextWindowAndCancelled() {
        #expect(!IntelligenceError.refused.isRetryable)
        #expect(!IntelligenceError.unsupportedLanguage.isRetryable)
        #expect(!IntelligenceError.contextWindowExceeded.isRetryable)
        #expect(!IntelligenceError.cancelled.isRetryable)
    }

    @Test func shouldStoreNoInsightIsTrueOnlyForRefused() {
        let allCases: [IntelligenceError] = [
            .contextWindowExceeded, .refused, .unsupportedLanguage, .throttled,
            .modelUnavailable, .malformedOutput, .cancelled, .unknown
        ]
        for error in allCases {
            #expect(error.shouldStoreNoInsight == (error == .refused))
        }
    }

    @Test func initPassesThroughAnAlreadyMappedIntelligenceErrorUnchanged() {
        for error: IntelligenceError in [.refused, .throttled, .unknown, .cancelled] {
            #expect(IntelligenceError(error) == error)
        }
    }

    @Test func initMapsCancellationErrorToCancelled() {
        #expect(IntelligenceError(CancellationError()) == .cancelled)
    }

    @Test func initMapsAnUnrelatedErrorToUnknown() {
        #expect(IntelligenceError(SomeOtherError()) == .unknown)
    }

    // MARK: - Missing model assets (critical fix, cycle 2)
    //
    // The real `FoundationModels.LanguageModelError` this classification targets is not
    // constructible from outside the framework (no public initializer, and its underlying
    // `LanguageModelError` case itself is iOS 27-only while this package's minimum deployment
    // is iOS 26). But `IntelligenceError.init`'s classification only inspects a plain `NSError`
    // domain/code chain — it never needs a real framework instance — so it *is* testable by
    // constructing an equivalent `NSError` chain by hand, matching the verbatim shape captured
    // while diagnosing this (see `changes.md` "Fix cycle 2" and `IntelligenceError.swift`).

    private func missingModelAssetsNSError() -> NSError {
        let unifiedAssetFrameworkError = NSError(
            domain: "com.apple.UnifiedAssetFramework",
            code: 5000,
            userInfo: [NSLocalizedDescriptionKey: "There are no underlying assets ..."]
        )
        let modelManagerError = NSError(
            domain: "ModelManagerServices.ModelManagerError",
            code: 1026,
            userInfo: [NSUnderlyingErrorKey: unifiedAssetFrameworkError]
        )
        let innerLanguageModelError = NSError(
            domain: "FoundationModels.LanguageModelError",
            code: -1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [modelManagerError]]
        )
        return NSError(
            domain: "FoundationModels.LanguageModelError",
            code: -1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [innerLanguageModelError]]
        )
    }

    @Test func initMapsTheDiagnosedMissingModelAssetsErrorChainToModelUnavailable() {
        #expect(IntelligenceError(missingModelAssetsNSError()) == .modelUnavailable)
    }

    @Test func initMapsAnNSErrorWithTheModelManagerErrorDomainDirectlyToModelUnavailable() {
        let error = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1026)
        #expect(IntelligenceError(error) == .modelUnavailable)
    }

    @Test func initMapsAnNSErrorWithTheUnifiedAssetFrameworkDomainDirectlyToModelUnavailable() {
        let error = NSError(domain: "com.apple.UnifiedAssetFramework", code: 5000)
        #expect(IntelligenceError(error) == .modelUnavailable)
    }

    @Test func initDoesNotMapAnUnrelatedNSErrorInTheLanguageModelErrorDomainToModelUnavailable() {
        // The outer `FoundationModels.LanguageModelError` domain alone is too broad to mean
        // "assets missing" — it wraps every undocumented internal failure. Without a nested
        // asset-specific domain in its underlying-error chain, this must fall through to
        // `.unknown`, not `.modelUnavailable`.
        let error = NSError(domain: "FoundationModels.LanguageModelError", code: -1)
        #expect(IntelligenceError(error) == .unknown)
    }
}
