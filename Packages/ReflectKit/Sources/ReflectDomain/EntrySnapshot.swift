import Foundation

/// A `Sendable` projection of a `JournalEntry`. SwiftData model objects must never cross an
/// actor boundary, so this is the currency between `JournalStore` and everything else.
nonisolated public struct EntrySnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let text: String
    public let source: EntrySource
    public let mood: Mood?
    public let summary: String?
    public let themeNames: [String]
    public let actionItemCount: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date = .now,
        text: String,
        source: EntrySource = .typed,
        mood: Mood? = nil,
        summary: String? = nil,
        themeNames: [String] = [],
        actionItemCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.source = source
        self.mood = mood
        self.summary = summary
        self.themeNames = themeNames
        self.actionItemCount = actionItemCount
    }

    /// Projects a model object. Callers stay off the main actor's model object graph after
    /// this returns; only `Sendable` values are kept.
    nonisolated public init(_ entry: JournalEntry) {
        self.id = entry.id
        self.createdAt = entry.createdAt
        self.updatedAt = entry.updatedAt
        self.text = entry.text
        self.source = entry.source
        self.mood = entry.mood
        self.summary = entry.insight?.summary
        self.themeNames = entry.themes.map(\.displayName)
        self.actionItemCount = entry.actionItems.count
    }

    /// First ~140 characters, whitespace-collapsed, for use in list rows.
    public var preview: String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if collapsed.count <= 140 {
            return collapsed
        }
        return String(collapsed.prefix(140))
    }
}
