import Testing
import Foundation
import SwiftData
@testable import ReflectDomain

struct SchemaRelationshipTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ReflectModelContainer.makeInMemory())
    }

    @Test func deletingEntryCascadesInsightAndActionItems() throws {
        let context = try makeContext()
        let entry = JournalEntry(text: "Entry with insight and action items")
        let insight = EntryInsight(
            summary: "Summary",
            mood: .good,
            moodConfidence: 0.9,
            modelIdentifier: "test-model",
            entry: entry
        )
        entry.insight = insight
        let item1 = ActionItem(title: "Call dentist", entry: entry)
        let item2 = ActionItem(title: "Buy milk", entry: entry)
        entry.actionItems = [item1, item2]

        context.insert(entry)
        try context.save()

        context.delete(entry)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<EntryInsight>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ActionItem>()) == 0)
    }

    @Test func deletingEntryWithThemeLeavesThemeAliveNullified() throws {
        let context = try makeContext()
        let entryA = JournalEntry(text: "Entry A")
        let entryB = JournalEntry(text: "Entry B")
        let theme = Theme(name: "coffee", displayName: "Coffee")
        theme.entries = [entryA, entryB]
        entryA.themes = [theme]
        entryB.themes = [theme]

        context.insert(theme)
        context.insert(entryA)
        context.insert(entryB)
        try context.save()

        #expect(theme.occurrenceCount == 2)

        context.delete(entryA)
        try context.save()

        let themes = try context.fetch(FetchDescriptor<Theme>())
        #expect(themes.count == 1)
        #expect(themes.first?.entries.count == 1)
    }

    @Test func attachingOneThemeToTwoEntriesYieldsOccurrenceCountTwo() throws {
        let context = try makeContext()
        let entryA = JournalEntry(text: "Entry A")
        let entryB = JournalEntry(text: "Entry B")
        let theme = Theme(name: "running", displayName: "Running")
        entryA.themes = [theme]
        entryB.themes = [theme]
        theme.entries = [entryA, entryB]

        context.insert(theme)
        context.insert(entryA)
        context.insert(entryB)
        try context.save()

        #expect(theme.occurrenceCount == 2)
    }

    @Test func insertingSecondThemeWithSameNameDoesNotProduceTwoRows() throws {
        let context = try makeContext()
        context.insert(Theme(name: "coffee", displayName: "Coffee"))
        try context.save()

        context.insert(Theme(name: "coffee", displayName: "Coffee again"))
        try context.save()

        let themes = try context.fetch(FetchDescriptor<Theme>())
        #expect(themes.count == 1)
    }
}
