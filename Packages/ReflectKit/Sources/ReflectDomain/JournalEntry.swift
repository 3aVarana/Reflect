import Foundation
import SwiftData

/// How an entry was captured.
nonisolated public enum EntrySource: String, Codable, Sendable {
    case typed
    case voice
}

/// A single free-form journal entry. AI enrichment lives alongside it and is
/// always optional: the raw text is the source of truth, insight is derived.
@Model
nonisolated public final class JournalEntry {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var text: String
    public var source: EntrySource

    /// Mood detected by the on-device model. `nil` until enrichment has run.
    public var mood: Mood?

    /// 1:1 with the latest analysis. Cascades on entry delete.
    @Relationship(deleteRule: .cascade, inverse: \EntryInsight.entry)
    public var insight: EntryInsight?

    /// Extracted intentions. Cascades on entry delete.
    @Relationship(deleteRule: .cascade, inverse: \ActionItem.entry)
    public var actionItems: [ActionItem] = []

    /// Many-to-many with `Theme`. The inverse relationship (with `inverse:`) is declared on
    /// `Theme` — SwiftData requires exactly one side of a relationship to declare it.
    public var themes: [Theme] = []

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        text: String,
        source: EntrySource = .typed
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.text = text
        self.source = source
    }

    /// Updates the entry's text and bumps `updatedAt` together, so no caller can change
    /// the text without advancing the modification timestamp.
    public func touch(text: String, now: Date = .now) {
        self.text = text
        self.updatedAt = now
    }
}
