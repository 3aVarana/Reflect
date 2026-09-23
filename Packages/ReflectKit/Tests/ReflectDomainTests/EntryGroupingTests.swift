import Testing
import Foundation
@testable import ReflectDomain

struct EntryGroupingTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func threeEntriesAcrossTwoDaysProduceTwoSectionsNewestFirst() {
        let calendar = utc
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9))!
        let day1Later = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 20))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 9))!

        let snapshots = [
            EntrySnapshot(createdAt: day1, text: "Day 1 morning"),
            EntrySnapshot(createdAt: day1Later, text: "Day 1 evening"),
            EntrySnapshot(createdAt: day2, text: "Day 2 morning")
        ]

        let sections = groupedByDay(snapshots, calendar: calendar)
        #expect(sections.count == 2)
        #expect(sections[0].day > sections[1].day)
        #expect(sections[0].entries.map(\.text) == ["Day 2 morning"])
        #expect(sections[1].entries.map(\.text) == ["Day 1 evening", "Day 1 morning"])
    }

    @Test func entryAt2359AndEntryAt0001LandInDifferentSections() {
        let calendar = utc
        let lateNight = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 23, minute: 59))!
        let earlyMorning = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 0, minute: 1))!

        let snapshots = [
            EntrySnapshot(createdAt: lateNight, text: "Late night"),
            EntrySnapshot(createdAt: earlyMorning, text: "Early morning")
        ]

        let sections = groupedByDay(snapshots, calendar: calendar)
        #expect(sections.count == 2)
    }

    @Test func emptyInputProducesEmptyOutput() {
        #expect(groupedByDay([], calendar: utc).isEmpty)
    }
}
