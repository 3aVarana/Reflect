import Testing
import Foundation
import FoundationModels
import ReflectDomain
@testable import ReflectIntelligence

/// The only suite that touches the real on-device model. Every test is gated on
/// `SystemLanguageModel.default.isAvailable` so CI and any machine without Apple Intelligence
/// enabled skips rather than fails. Assertions only ever check the mood *band* (positive vs.
/// negative), never an exact `Mood` case or exact wording — the model's precise phrasing is
/// not something this suite should pin down.
struct LiveEntryAnalysisTests {
    nonisolated private struct GoldenEntry: Sendable {
        let text: String
        let expectedBand: Band
    }

    nonisolated private enum Band: Sendable {
        case positive
        case negative
        case either
    }

    // `nonisolated`: the `@Test(arguments:)` macro evaluates this outside the main actor
    // during test discovery.
    nonisolated private static let goldenEntries: [GoldenEntry] = [
        GoldenEntry(
            text: "I got the promotion I've been working toward all year. I'm thrilled and so proud of myself.",
            expectedBand: .positive
        ),
        GoldenEntry(
            text: "Today was wonderful. I went for a long walk with my best friend and we laughed the whole time.",
            expectedBand: .positive
        ),
        GoldenEntry(
            text: "I finally finished the marathon I've trained six months for. I feel incredible.",
            expectedBand: .positive
        ),
        GoldenEntry(
            text: "My grandmother passed away last night. I don't know how to process this loss.",
            expectedBand: .negative
        ),
        GoldenEntry(
            text: "I got into an argument with my closest friend and now I feel completely alone.",
            expectedBand: .negative
        ),
        GoldenEntry(
            text: "I lost my job today with no warning. I'm scared about how I'll pay rent next month.",
            expectedBand: .negative
        ),
        GoldenEntry(
            text: "Woke up, made coffee, answered some emails, had a sandwich for lunch.",
            expectedBand: .either
        ),
        GoldenEntry(
            text: "Spent the afternoon reorganizing my bookshelf by color. Not sure why, just felt like it.",
            expectedBand: .either
        ),
        GoldenEntry(
            text: "The meeting ran long and I still have three more things on my list before dinner.",
            expectedBand: .either
        ),
        GoldenEntry(
            text: "I planted tomatoes in the garden this morning and watched a documentary tonight.",
            expectedBand: .either
        )
    ]

    /// A real capability probe, not just `SystemLanguageModel.default.isAvailable`.
    ///
    /// Diagnosed while investigating a fully-red run of this suite: on this project's
    /// sandboxed build host, `isAvailable` reports `true` (the eligibility/guardrail check
    /// passes) while the on-device model's assets are not actually installed. Every real
    /// generation request then fails immediately with a raw, undocumented `NSError` — *not* a
    /// `LanguageModelSession.GenerationError` case — which `IntelligenceError.init` now
    /// classifies as `.modelUnavailable` by matching the error's domain/code chain (see
    /// `IntelligenceError.swift`). Since `isAvailable == true` does not, on this host, imply a
    /// working model, the probe below performs one real trivial generation up front and caches
    /// the result — but it classifies the outcome rather than swallowing it:
    ///
    /// - `!isAvailable`, or the probe's own generation fails with exactly `.modelUnavailable`:
    ///   the environment genuinely cannot generate, so the suite *skips*.
    /// - Any other outcome — `.malformedOutput`, `.refused`, `.throttled`, `.unknown`, or a
    ///   stream that ends with no `.finished` and no thrown error at all — means the engine is
    ///   broken in some way that is *not* "assets aren't installed", so the probe reports
    ///   "enabled" and lets the ten real test cases run and fail loudly on their own. The probe
    ///   must never be the only place that outcome is visible.
    private actor CapabilityProbe {
        static let shared = CapabilityProbe()

        private var cached: Bool?

        /// `true` means "run the suite" (either generation genuinely works, or the failure is
        /// not the diagnosed environmental case and must surface as a real, loud test failure).
        /// `false` means "skip": `!isAvailable`, or the probe's own attempt failed with exactly
        /// `.modelUnavailable`.
        func shouldRun() async -> Bool {
            if let cached { return cached }
            let result = await Self.probe()
            cached = result
            return result
        }

        private static func probe() async -> Bool {
            guard SystemLanguageModel.default.isAvailable else { return false }
            let engine = IntelligenceEngine()
            do {
                for try await event in await engine.analyze("A quick capability probe entry.") {
                    if case .finished = event { return true }
                }
                // The stream ended with neither `.finished` nor a thrown error. That is not the
                // diagnosed "assets missing" case, so the suite must run and fail visibly rather
                // than fold this into a silent skip.
                return true
            } catch {
                return IntelligenceError(error) != .modelUnavailable
            }
        }
    }

    @Test(
        .enabled(
            """
            Requires a host that can actually generate; skips only when the model's assets
            aren't installed, not on any other failure
            """
        ) { await CapabilityProbe.shared.shouldRun() },
        arguments: Self.goldenEntries.indices
    )
    func analysisOfGoldenEntryReturnsWellFormedResultInTheExpectedMoodBand(index: Int) async throws {
        let entry = Self.goldenEntries[index]
        let engine = IntelligenceEngine()

        var finalResult: AnalysisResult?
        for try await event in await engine.analyze(entry.text) {
            if case .finished(let result) = event {
                finalResult = result
            }
        }
        let result = try #require(finalResult)

        #expect(!result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!(result.reflectionQuestion ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect((0...1).contains(result.moodConfidence))

        switch entry.expectedBand {
        case .positive:
            #expect(result.mood.score >= 0)
        case .negative:
            #expect(result.mood.score <= 0)
        case .either:
            break
        }
    }
}
