import Foundation
import SwiftData

/// How an entry was captured.
public enum EntrySource: String, Codable, Sendable {
    case typed
    case voice
}

/// A single free-form journal entry. AI enrichment lives alongside it and is
/// always optional: the raw text is the source of truth, insight is derived.
@Model
public final class JournalEntry {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var text: String
    public var source: EntrySource

    /// Mood detected by the on-device model. `nil` until enrichment has run.
    public var mood: Mood?

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
}
