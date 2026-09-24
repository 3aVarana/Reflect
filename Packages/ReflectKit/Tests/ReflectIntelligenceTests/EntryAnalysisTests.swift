import Testing
import Foundation
import ReflectDomain
@testable import ReflectIntelligence

/// Warning fix: these two mappings were missing from the plan's own test plan despite guarding
/// the exact translation that carries generated output into persistence. A transposed case
/// here (e.g. `.veryLow → .low`) would silently mis-record the mood of every insight and every
/// list glyph, and nothing else in the suite would notice.
struct EntryAnalysisTests {
    @Test(arguments: Mood.allCases)
    func moodTagRoundTripsThroughMoodForEveryCase(mood: Mood) {
        let tag = MoodTag(mood)
        #expect(tag.mood == mood)
    }

    @Test func moodTagCasesMapOneToOneOntoMoodCases() {
        // Every `Mood` case must have exactly one corresponding `MoodTag` case with a matching
        // name, so the guided-generation vocabulary never silently drifts from the persisted
        // domain type.
        let allTags: [MoodTag] = [.veryLow, .low, .neutral, .good, .great]
        let mapped = Set(allTags.map(\.mood))
        #expect(mapped == Set(Mood.allCases))
    }

    @Test func analysisResultDraftCopiesEveryFieldFieldForField() {
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let result = AnalysisResult(
            mood: .great,
            moodConfidence: 0.87,
            summary: "You had a wonderful day.",
            reflectionQuestion: "What made it so good?",
            isPartialText: true,
            modelIdentifier: "system-language-model.general"
        )

        let draft = result.draft(generatedAt: generatedAt)

        #expect(draft.summary == result.summary)
        #expect(draft.reflectionQuestion == result.reflectionQuestion)
        #expect(draft.mood == result.mood)
        #expect(draft.moodConfidence == result.moodConfidence)
        #expect(draft.modelIdentifier == result.modelIdentifier)
        #expect(draft.isPartial == result.isPartialText)
        #expect(draft.generatedAt == generatedAt)
        #expect(draft.analysisVersion == AnalysisVersion.current)
    }

    @Test func analysisResultDraftPreservesANilReflectionQuestion() {
        // A blank generated question is normalised to `nil` by the caller before an
        // `AnalysisResult` is even constructed (see `IntelligenceEngine`); `draft()` itself
        // must not reintroduce an empty string for it.
        let result = AnalysisResult(
            mood: .neutral,
            moodConfidence: 0.5,
            summary: "A short, neutral day.",
            reflectionQuestion: nil,
            isPartialText: false,
            modelIdentifier: "test"
        )

        let draft = result.draft()

        #expect(draft.reflectionQuestion == nil)
    }

    @Test func analysisResultDraftClampsConfidenceViaInsightDraft() {
        // `InsightDraft`'s initializer clamps `moodConfidence` into `0...1`; `draft()` must
        // route through that initializer (not assign the field directly) so an out-of-range
        // model value is still clamped by the time it reaches `JournalStore`.
        let result = AnalysisResult(
            mood: .low,
            moodConfidence: 4.2,
            summary: "Text",
            reflectionQuestion: nil,
            isPartialText: false,
            modelIdentifier: "test"
        )

        let draft = result.draft()

        #expect(draft.moodConfidence == 1.0)
    }
}
