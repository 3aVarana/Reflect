import Foundation
import FoundationModels
import ReflectDomain

/// `@Generable` mirror of `ReflectDomain.Mood`. `Mood` itself cannot carry `@Generable` —
/// that macro requires `import FoundationModels`, which is banned inside `ReflectDomain` — so
/// this type exists purely as the guided-generation vocabulary, translated to/from `Mood`
/// immediately after generation.
@Generable
nonisolated public enum MoodTag: Sendable {
    case veryLow
    case low
    case neutral
    case good
    case great

    public var mood: Mood {
        switch self {
        case .veryLow: .veryLow
        case .low: .low
        case .neutral: .neutral
        case .good: .good
        case .great: .great
        }
    }

    public init(_ mood: Mood) {
        switch mood {
        case .veryLow: self = .veryLow
        case .low: self = .low
        case .neutral: self = .neutral
        case .good: self = .good
        case .great: self = .great
        }
    }
}

/// The guided-generation schema for a single entry's analysis. Declaration order matters:
/// generation follows it, and the insight panel renders mood first.
///
/// Themes and action items are deliberately out of this phase's schema (Phase 3 owns theme
/// normalisation and the action-item inbox); see the Phase 2 plan's Risks section.
@Generable
nonisolated public struct EntryAnalysis: Sendable {
    @Guide(description: "Overall mood of the writer")
    public var mood: MoodTag

    @Guide(description: "How confident you are in the mood, 0 to 1", .range(0.0...1.0))
    public var moodConfidence: Double

    @Guide(description: "One sentence, second person, describing what the entry is about. No advice.")
    public var summary: String

    @Guide(description: "One open question that helps the writer reflect further. No advice, no judgement.")
    public var reflectionQuestion: String
}

/// A `Sendable` snapshot of an in-progress `EntryAnalysis.PartiallyGenerated`, so streamed
/// partials can cross out of the actor that owns the (non-`Sendable`) `LanguageModelSession`
/// without smuggling the macro-generated partial type itself across the boundary.
nonisolated public struct AnalysisPartial: Sendable, Equatable {
    public let mood: Mood?
    public let moodConfidence: Double?
    public let summary: String?
    public let reflectionQuestion: String?

    public init(
        mood: Mood? = nil,
        moodConfidence: Double? = nil,
        summary: String? = nil,
        reflectionQuestion: String? = nil
    ) {
        self.mood = mood
        self.moodConfidence = moodConfidence
        self.summary = summary
        self.reflectionQuestion = reflectionQuestion
    }

    /// Mood is deliberately left `nil` while streaming: `MoodTag`'s partial form is generated
    /// as a whole-or-nothing enum case rather than a field-by-field partial, so reading it
    /// mid-stream is not meaningfully "partial". The `.finished` event supplies the final
    /// mood instead; the panel already renders `MoodGlyph(mood: nil)` as a dashed placeholder,
    /// so this degrades cleanly.
    public init(_ partial: EntryAnalysis.PartiallyGenerated) {
        self.mood = nil
        self.moodConfidence = partial.moodConfidence
        self.summary = partial.summary
        self.reflectionQuestion = partial.reflectionQuestion
    }
}

/// The final, `Sendable` result of one analysis run.
nonisolated public struct AnalysisResult: Sendable, Equatable {
    public let mood: Mood
    public let moodConfidence: Double
    public let summary: String
    public let reflectionQuestion: String?
    public let isPartialText: Bool
    public let modelIdentifier: String

    public init(
        mood: Mood,
        moodConfidence: Double,
        summary: String,
        reflectionQuestion: String?,
        isPartialText: Bool,
        modelIdentifier: String
    ) {
        self.mood = mood
        self.moodConfidence = moodConfidence
        self.summary = summary
        self.reflectionQuestion = reflectionQuestion
        self.isPartialText = isPartialText
        self.modelIdentifier = modelIdentifier
    }

    public func draft(generatedAt: Date = .now) -> InsightDraft {
        InsightDraft(
            summary: summary,
            reflectionQuestion: reflectionQuestion,
            mood: mood,
            moodConfidence: moodConfidence,
            modelIdentifier: modelIdentifier,
            isPartial: isPartialText,
            generatedAt: generatedAt
        )
    }
}
