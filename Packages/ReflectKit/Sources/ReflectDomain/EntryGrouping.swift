import Foundation

/// One calendar day's worth of entries, newest first.
nonisolated public struct EntryDaySection: Identifiable, Hashable, Sendable {
    public let day: Date
    public let entries: [EntrySnapshot]

    public var id: Date { day }

    public init(day: Date, entries: [EntrySnapshot]) {
        self.day = day
        self.entries = entries
    }
}

/// Groups snapshots by calendar day. Sections are sorted newest day first; entries within
/// a section are sorted newest first.
nonisolated public func groupedByDay(
    _ snapshots: [EntrySnapshot],
    calendar: Calendar = .current
) -> [EntryDaySection] {
    let grouped = Dictionary(grouping: snapshots) { calendar.startOfDay(for: $0.createdAt) }
    return grouped
        .map { day, entries in
            EntryDaySection(day: day, entries: entries.sorted { $0.createdAt > $1.createdAt })
        }
        .sorted { $0.day > $1.day }
}
