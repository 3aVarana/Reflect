import Foundation
import SwiftData

/// Bumped whenever the analysis prompt or `@Generable` schema changes; a stored insight
/// with an older version should be treated as stale and re-computed. Phase 2 is the first
/// writer of this value; this is the one place to bump it going forward.
nonisolated public enum AnalysisVersion {
    public static let current = 1
}

/// The result of running the on-device model over a single entry's text. Always optional
/// and always derived — the entry's raw text remains the source of truth.
@Model
nonisolated public final class EntryInsight {
    public var summary: String
    public var reflectionQuestion: String?
    public var mood: Mood
    public var moodConfidence: Double
    public var analysisVersion: Int
    public var modelIdentifier: String
    public var generatedAt: Date

    /// Set when the entry text exceeded the model's context window and only a prefix was
    /// analyzed.
    public var isPartial: Bool = false

    /// Inverse lives on `JournalEntry.insight`; kept plain (no `@Relationship`) here.
    public var entry: JournalEntry?

    public init(
        summary: String,
        reflectionQuestion: String? = nil,
        mood: Mood,
        moodConfidence: Double,
        analysisVersion: Int = AnalysisVersion.current,
        modelIdentifier: String,
        generatedAt: Date = .now,
        isPartial: Bool = false,
        entry: JournalEntry? = nil
    ) {
        self.summary = summary
        self.reflectionQuestion = reflectionQuestion
        self.mood = mood
        self.moodConfidence = moodConfidence
        self.analysisVersion = analysisVersion
        self.modelIdentifier = modelIdentifier
        self.generatedAt = generatedAt
        self.isPartial = isPartial
        self.entry = entry
    }
}
