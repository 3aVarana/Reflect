import Foundation
import SwiftData

/// A recurring topic across entries. `name` is expected to already be normalised
/// (lowercased, trimmed) by the caller — Phase 3 owns normalisation logic; this phase just
/// stores whatever it is given.
@Model
nonisolated public final class Theme {
    @Attribute(.unique) public var name: String
    public var displayName: String
    public var firstSeen: Date
    public var lastSeen: Date

    /// Many-to-many inverse of `JournalEntry.themes`. SwiftData requires exactly one side
    /// of the relationship to declare `inverse:`; this is that side.
    @Relationship(deleteRule: .nullify, inverse: \JournalEntry.themes)
    public var entries: [JournalEntry] = []

    public var occurrenceCount: Int { entries.count }

    public init(
        name: String,
        displayName: String,
        firstSeen: Date = .now,
        lastSeen: Date = .now
    ) {
        self.name = name
        self.displayName = displayName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}
