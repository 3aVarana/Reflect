import Testing
import Foundation
import SwiftData
@testable import ReflectDomain

struct JournalStoreTests {
    private func makeStore() throws -> JournalStore {
        JournalStore(modelContainer: try ReflectModelContainer.makeInMemory())
    }

    @Test func insertReturnsSnapshotWithMatchingTextAndFreshID() async throws {
        let store = try makeStore()
        let snapshot = try await store.insert(text: "First entry")
        #expect(snapshot.text == "First entry")
        let roundTripped = try await store.snapshot(id: snapshot.id)
        #expect(roundTripped?.id == snapshot.id)
    }

    @Test func insertThenSnapshotsRoundTripsNewestFirst() async throws {
        let store = try makeStore()
        let now = Date.now
        _ = try await store.insert(text: "Older", createdAt: now.addingTimeInterval(-100))
        _ = try await store.insert(text: "Newer", createdAt: now)

        let snapshots = try await store.snapshots()
        #expect(snapshots.map(\.text) == ["Newer", "Older"])
    }

    @Test func updateChangesTextAndAdvancesUpdatedAtLeavingCreatedAtAlone() async throws {
        let store = try makeStore()
        let created = try await store.insert(text: "Original")
        let later = created.createdAt.addingTimeInterval(60)

        let updated = try await store.update(id: created.id, text: "Edited", now: later)
        #expect(updated?.text == "Edited")
        #expect(updated?.updatedAt == later)
        #expect(updated?.createdAt == created.createdAt)
    }

    @Test func updateOnUnknownIDReturnsNil() async throws {
        let store = try makeStore()
        let result = try await store.update(id: UUID(), text: "Nope")
        #expect(result == nil)
    }

    @Test func deleteOnUnknownIDReturnsFalse() async throws {
        let store = try makeStore()
        let result = try await store.delete(id: UUID())
        #expect(result == false)
    }

    @Test func deleteRemovesExactlyOneRow() async throws {
        let store = try makeStore()
        let entryA = try await store.insert(text: "A")
        _ = try await store.insert(text: "B")

        let deleted = try await store.delete(id: entryA.id)
        #expect(deleted == true)

        let remaining = try await store.snapshots()
        #expect(remaining.count == 1)
        #expect(remaining.first?.text == "B")
    }

    @Test func deleteAllEmptiesStoreIncludingThemeAndWeeklyDigest() async throws {
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        _ = try await store.insert(text: "Entry")

        let context = ModelContext(container)
        context.insert(Theme(name: "coffee", displayName: "Coffee"))
        context.insert(WeeklyDigest(
            weekStart: .now,
            headline: "Headline",
            narrative: "Narrative",
            averageMoodScore: 0,
            entryCount: 1
        ))
        try context.save()

        try await store.deleteAll()

        let entries = try await store.snapshots()
        #expect(entries.isEmpty)
        let themeCount = try context.fetchCount(FetchDescriptor<Theme>())
        let digestCount = try context.fetchCount(FetchDescriptor<WeeklyDigest>())
        #expect(themeCount == 0)
        #expect(digestCount == 0)
    }

    @Test func searchIsCaseAndDiacriticInsensitive() async throws {
        let store = try makeStore()
        _ = try await store.insert(text: "Coffee with Ana")
        _ = try await store.insert(text: "Ran 5k")

        let caseInsensitive = try await store.snapshots(matching: "ANA")
        #expect(caseInsensitive.count == 1)
        #expect(caseInsensitive.first?.text == "Coffee with Ana")

        _ = try await store.insert(text: "Dinner with Aná")
        let diacriticInsensitive = try await store.snapshots(matching: "ana")
        #expect(diacriticInsensitive.count == 2)
        #expect(Set(diacriticInsensitive.map(\.text)) == ["Coffee with Ana", "Dinner with Aná"])
    }

    @Test func searchWithNonMatchingQueryReturnsNothing() async throws {
        let store = try makeStore()
        _ = try await store.insert(text: "Coffee with Ana")

        let results = try await store.snapshots(matching: "zzz-no-match")
        #expect(results.isEmpty)
    }

    @Test func snapshotsInRangeRespectsHalfOpenBounds() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(60)

        _ = try await store.insert(text: "At start", createdAt: start)
        _ = try await store.insert(text: "At end", createdAt: end)
        _ = try await store.insert(text: "Inside", createdAt: start.addingTimeInterval(30))

        let results = try await store.snapshots(in: DateRange(start: start, end: end))
        let texts = Set(results.map(\.text))
        #expect(texts == ["At start", "Inside"])
    }

    @Test func moodTrendAveragesSameDayEntriesAndSkipsNilMoodDays() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let day = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 9))!
        let sameDayLater = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 20))!

        _ = try await store.insert(text: "Good morning", createdAt: day)
        _ = try await store.insert(text: "Good evening", createdAt: sameDayLater)
        _ = try await store.insert(text: "No mood day", createdAt: day.addingTimeInterval(-86400))

        // Set moods directly through the context (store has no applyInsight in this phase).
        let context = ModelContext(container)
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        for entry in entries where entry.text == "Good morning" || entry.text == "Good evening" {
            entry.mood = .good
        }
        try context.save()

        let range = DateRange.lastDays(3, endingAt: sameDayLater, calendar: calendar)
        let trend = try await store.moodTrend(in: range, calendar: calendar)

        #expect(trend.count == 1)
        #expect(trend.first?.entryCount == 2)
        #expect(trend.first?.averageScore == Double(Mood.good.score))
    }
}
