import Foundation

/// Everything `EntryInsight` persists, as a `Sendable` value that can cross from the
/// enrichment actor (`ReflectIntelligence`) into `JournalStore` without touching a model
/// object or importing FoundationModels. Mirrors `EntrySnapshot`'s shape: `nonisolated`,
/// `Sendable`, memberwise `init`, no model references.
nonisolated public struct InsightDraft: Sendable, Equatable {
    public let summary: String
    public let reflectionQuestion: String?
    public let mood: Mood
    public let moodConfidence: Double
    public let modelIdentifier: String
    public let isPartial: Bool
    public let analysisVersion: Int
    public let generatedAt: Date

    /// Clamps `moodConfidence` into `0...1`: the model is guided to stay in range but guided
    /// generation is not a hard constraint, so an out-of-range value must never reach
    /// persistence or a confidence bar that renders past its bounds.
    public init(
        summary: String,
        reflectionQuestion: String? = nil,
        mood: Mood,
        moodConfidence: Double,
        modelIdentifier: String,
        isPartial: Bool = false,
        analysisVersion: Int = AnalysisVersion.current,
        generatedAt: Date = .now
    ) {
        self.summary = summary
        self.reflectionQuestion = reflectionQuestion
        self.mood = mood
        self.moodConfidence = min(max(moodConfidence, 0), 1)
        self.modelIdentifier = modelIdentifier
        self.isPartial = isPartial
        self.analysisVersion = analysisVersion
        self.generatedAt = generatedAt
    }
}
