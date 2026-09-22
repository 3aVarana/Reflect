import Foundation

/// A half-open date interval: `start <= x < end`.
nonisolated public struct DateRange: Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// The 24h span containing `date` in `calendar`.
    public static func day(containing date: Date, calendar: Calendar = .current) -> DateRange {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateRange(start: start, end: end)
    }

    /// The week containing `date`, honouring `calendar.firstWeekday`.
    public static func week(containing date: Date, calendar: Calendar = .current) -> DateRange {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)
        let start = interval?.start ?? calendar.startOfDay(for: date)
        let end = interval?.end ?? (calendar.date(byAdding: .day, value: 7, to: start) ?? start)
        return DateRange(start: start, end: end)
    }

    /// The `count`-day span ending (exclusive) the day after `endingAt`, i.e. the last
    /// `count` full calendar days up to and including `endingAt`'s day.
    public static func lastDays(_ count: Int, endingAt: Date, calendar: Calendar = .current) -> DateRange {
        let endOfDay = calendar.startOfDay(for: endingAt)
        let end = calendar.date(byAdding: .day, value: 1, to: endOfDay) ?? endOfDay
        let start = calendar.date(byAdding: .day, value: -count + 1, to: endOfDay) ?? endOfDay
        return DateRange(start: start, end: end)
    }
}
