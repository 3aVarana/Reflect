import Testing
import Foundation
@testable import ReflectFeatures

struct DayTitleFormatterTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Pin the locale too: the flexible date-component matching behind
        // `Date.FormatStyle` can silently abbreviate a `.wide` weekday when the active
        // process locale doesn't carry full symbol data (observed in this sandboxed test
        // run), which would make `titleForTenDaysAgoContainsWeekdayName` flaky for reasons
        // that have nothing to do with `DayTitleFormatter` itself.
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    @Test func titleForNowIsLocalizedToday() {
        // Compared against a fixed literal, not `String(localized:bundle: .module)`: inside
        // the test target, `.module` resolves to the test bundle rather than
        // `ReflectFeatures`', so a catalog lookup on both sides would pass vacuously (both
        // fall back to the key) rather than proving anything once the catalog is populated.
        let calendar = utc
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 13))!
        let title = DayTitleFormatter.title(for: now, relativeTo: now, calendar: calendar)
        #expect(title == "Today")
    }

    @Test func titleForYesterdayIsLocalizedYesterday() {
        let calendar = utc
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 13))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let title = DayTitleFormatter.title(for: yesterday, relativeTo: now, calendar: calendar)
        #expect(title == "Yesterday")
    }

    @Test func titleForTenDaysAgoContainsWeekdayName() {
        let calendar = utc
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 13))!
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!
        let title = DayTitleFormatter.title(for: tenDaysAgo, relativeTo: now, calendar: calendar)

        // Pin the same UTC time zone the formatter now honours (DayTitleFormatter.swift
        // review nit) so this comparison can't drift from the formatter's own output on a
        // CI host whose local time zone isn't UTC.
        var weekdayStyle = Date.FormatStyle.dateTime.weekday(.wide)
        weekdayStyle.timeZone = calendar.timeZone
        weekdayStyle.locale = calendar.locale ?? Locale(identifier: "en_US")
        let weekday = tenDaysAgo.formatted(weekdayStyle)
        #expect(title.contains(weekday))
    }
}
