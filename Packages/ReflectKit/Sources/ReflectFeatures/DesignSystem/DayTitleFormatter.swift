import Foundation

/// Formats a day for use as a list section header: "Today", "Yesterday", or a weekday/date,
/// with a year suffix when the day isn't in the current year. Pure and testable.
public enum DayTitleFormatter {
    public static func title(
        for day: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return String(localized: "Today", bundle: .module)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", bundle: .module)
        }

        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        var style = Date.FormatStyle.dateTime.weekday(.wide).month().day()
        style.timeZone = calendar.timeZone
        if let locale = calendar.locale {
            style.locale = locale
        }
        if sameYear {
            return day.formatted(style)
        }
        return day.formatted(style.year())
    }
}
