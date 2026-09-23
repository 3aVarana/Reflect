import Foundation
import SwiftData

/// A cached weekly summary keyed by the start of the week. Standalone — no relationships —
/// so it can be regenerated independently of the entries it was computed from. Nothing
/// writes into this table until Phase 4; the model lands now so the schema is final.
@Model
nonisolated public final class WeeklyDigest {
    @Attribute(.unique) public var weekStart: Date
    public var headline: String
    public var narrative: String
    public var highlights: [String] = []
    public var recurringThemes: [String] = []
    public var suggestedFocus: String?
    public var averageMoodScore: Double
    public var entryCount: Int
    public var generatedAt: Date
    public var analysisVersion: Int

    public init(
        weekStart: Date,
        headline: String,
        narrative: String,
        highlights: [String] = [],
        recurringThemes: [String] = [],
        suggestedFocus: String? = nil,
        averageMoodScore: Double,
        entryCount: Int,
        generatedAt: Date = .now,
        analysisVersion: Int = AnalysisVersion.current
    ) {
        self.weekStart = weekStart
        self.headline = headline
        self.narrative = narrative
        self.highlights = highlights
        self.recurringThemes = recurringThemes
        self.suggestedFocus = suggestedFocus
        self.averageMoodScore = averageMoodScore
        self.entryCount = entryCount
        self.generatedAt = generatedAt
        self.analysisVersion = analysisVersion
    }
}
