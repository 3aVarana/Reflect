import Foundation
import SwiftData

/// An explicit intention extracted from an entry ("I'll call the dentist tomorrow").
@Model
nonisolated public final class ActionItem {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var isCompleted: Bool = false
    public var completedAt: Date?
    public var createdAt: Date

    /// Inverse lives on `JournalEntry.actionItems`. Optional even though
    /// `docs/ARCHITECTURE.md` describes it as non-optional: SwiftData nils out the inverse
    /// side of a relationship during cascade teardown, so a non-optional stored property
    /// here would trap when the owning entry is deleted.
    public var entry: JournalEntry?

    public init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date = .now,
        entry: JournalEntry? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.entry = entry
    }
}
