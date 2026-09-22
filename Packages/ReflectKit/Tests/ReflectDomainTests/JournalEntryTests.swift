import Testing
import SwiftData
@testable import ReflectDomain

struct JournalEntryTests {
    @Test func insertsAndFetchesEntry() throws {
        let container = try ReflectModelContainer.makeInMemory()
        let context = ModelContext(container)
        context.insert(JournalEntry(text: "First entry"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<JournalEntry>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.text == "First entry")
        #expect(fetched.first?.mood == nil)
    }

    @Test func moodScoresAreOrdered() {
        let scores = Mood.allCases.map(\.score)
        #expect(scores == scores.sorted())
    }
}
