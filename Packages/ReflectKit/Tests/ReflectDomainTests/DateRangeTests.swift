import Testing
import Foundation
@testable import ReflectDomain

struct DateRangeTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func dayContainingSpansExactly24Hours() {
        let calendar = utc
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 13))!
        let range = DateRange.day(containing: date, calendar: calendar)
        #expect(range.end.timeIntervalSince(range.start) == 24 * 60 * 60)
    }

    @Test func containsIsInclusiveOfStartExclusiveOfEnd() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(100)
        let range = DateRange(start: start, end: end)
        #expect(range.contains(start))
        #expect(!range.contains(end))
        #expect(range.contains(start.addingTimeInterval(50)))
    }

    @Test func lastDaysSpansSevenDays() {
        let calendar = utc
        let endingAt = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 13))!
        let range = DateRange.lastDays(7, endingAt: endingAt, calendar: calendar)
        #expect(range.end.timeIntervalSince(range.start) == 7 * 24 * 60 * 60)
    }
}
