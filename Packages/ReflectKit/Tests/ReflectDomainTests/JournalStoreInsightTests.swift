import Testing
import Foundation
import SwiftData
@testable import ReflectDomain

struct JournalStoreInsightTests {
    private func makeStore() throws -> JournalStore {
        JournalStore(modelContainer: try ReflectModelContainer.makeInMemory())
    }

    private func draft(
        summary: String = "Summary",
        reflectionQuestion: String? = "Question?",
        mood: Mood = .good,
        moodConfidence: Double = 0.7,
        modelIdentifier: String = "test-model",
        isPartial: Bool = false,
        analysisVersion: Int = AnalysisVersion.current,
        generatedAt: Date = .now
    ) -> InsightDraft {
        InsightDraft(
            summary: summary,
            reflectionQuestion: reflectionQuestion,
            mood: mood,
            moodConfidence: moodConfidence,
            modelIdentifier: modelIdentifier,
            isPartial: isPartial,
            analysisVersion: analysisVersion,
            generatedAt: generatedAt
        )
    }

    @Test func applyInsightCreatesOneRowAndSetsEntryMood() async throws {
        let store = try makeStore()
        let entry = try await store.insert(text: "First entry")

        let snapshot = try await store.applyInsight(entryID: entry.id, draft: draft(mood: .great))

        #expect(snapshot?.mood == .great)
    }

    @Test func secondApplyInsightMutatesExistingRowRatherThanInsertingASecondOne() async throws {
        // Regression coverage for the acceptance criterion: applying two different drafts to
        // the same entry must leave exactly one EntryInsight row, not orphan the first.
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "First entry")

        _ = try await store.applyInsight(entryID: entry.id, draft: draft(summary: "First pass", mood: .low))
        let second = try await store.applyInsight(entryID: entry.id, draft: draft(summary: "Second pass", mood: .great))

        #expect(second?.mood == .great)

        let context = ModelContext(container)
        let insightRows = try context.fetch(FetchDescriptor<EntryInsight>())
        #expect(insightRows.count == 1)
        #expect(insightRows.first?.summary == "Second pass")
    }

    @Test func applyInsightDoesNotAdvanceUpdatedAt() async throws {
        // Enrichment is not a user edit: idsNeedingAnalysis compares generatedAt against
        // updatedAt, so applyInsight must never touch it.
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "First entry")
        let updatedAtBefore = entry.updatedAt

        _ = try await store.applyInsight(entryID: entry.id, draft: draft())

        let context = ModelContext(container)
        let entryID = entry.id
        var descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == entryID })
        descriptor.fetchLimit = 1
        let refetched = try #require(try context.fetch(descriptor).first)
        #expect(refetched.updatedAt == updatedAtBefore)
    }

    @Test func applyInsightOnUnknownIDReturnsNil() async throws {
        let store = try makeStore()
        let result = try await store.applyInsight(entryID: UUID(), draft: draft())
        #expect(result == nil)
    }

    @Test func clearInsightRemovesRowAndNilsMood() async throws {
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "First entry")
        _ = try await store.applyInsight(entryID: entry.id, draft: draft(mood: .great))

        let cleared = try await store.clearInsight(entryID: entry.id)
        #expect(cleared == true)

        let context = ModelContext(container)
        let insightRows = try context.fetch(FetchDescriptor<EntryInsight>())
        #expect(insightRows.isEmpty)

        let snapshot = try await store.snapshot(id: entry.id)
        #expect(snapshot?.mood == nil)
    }

    @Test func clearInsightOnUnknownIDReturnsFalse() async throws {
        let store = try makeStore()
        let result = try await store.clearInsight(entryID: UUID())
        #expect(result == false)
    }

    @Test func deletingEntryCascadesInsightToZeroRows() async throws {
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "First entry")
        _ = try await store.applyInsight(entryID: entry.id, draft: draft())

        _ = try await store.delete(id: entry.id)

        let context = ModelContext(container)
        let insightRows = try context.fetch(FetchDescriptor<EntryInsight>())
        #expect(insightRows.isEmpty)
    }

    @Test func idsNeedingAnalysisIncludesEntryWithNoInsight() async throws {
        let store = try makeStore()
        let entry = try await store.insert(text: "No insight yet")

        let ids = try await store.idsNeedingAnalysis()
        #expect(ids.contains(entry.id))
    }

    @Test func idsNeedingAnalysisIncludesEntryWithOlderAnalysisVersion() async throws {
        let store = try makeStore()
        let entry = try await store.insert(text: "Stale version")
        _ = try await store.applyInsight(entryID: entry.id, draft: draft(analysisVersion: 0))

        let ids = try await store.idsNeedingAnalysis(currentVersion: 1)
        #expect(ids.contains(entry.id))
    }

    @Test func idsNeedingAnalysisIncludesEntryEditedAfterGeneratedAt() async throws {
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "Original")
        let generatedAt = entry.createdAt
        _ = try await store.applyInsight(entryID: entry.id, draft: draft(generatedAt: generatedAt))

        // Edit the entry after the insight was generated.
        _ = try await store.update(id: entry.id, text: "Edited", now: generatedAt.addingTimeInterval(60))

        let ids = try await store.idsNeedingAnalysis()
        #expect(ids.contains(entry.id))
    }

    @Test func idsNeedingAnalysisExcludesUpToDateEntry() async throws {
        let store = try makeStore()
        let entry = try await store.insert(text: "Up to date")
        // generatedAt after the entry's updatedAt, and at the current version.
        _ = try await store.applyInsight(
            entryID: entry.id,
            draft: draft(analysisVersion: AnalysisVersion.current, generatedAt: .now.addingTimeInterval(60))
        )

        let ids = try await store.idsNeedingAnalysis()
        #expect(!ids.contains(entry.id))
    }

    @Test func idsNeedingAnalysisExcludesBlankTextEntry() async throws {
        let store = try makeStore()
        let entry = try await store.insert(text: "   ")

        let ids = try await store.idsNeedingAnalysis()
        #expect(!ids.contains(entry.id))
    }

    @Test func idsNeedingAnalysisRespectsLimit() async throws {
        let store = try makeStore()
        _ = try await store.insert(text: "One")
        _ = try await store.insert(text: "Two")
        _ = try await store.insert(text: "Three")

        let ids = try await store.idsNeedingAnalysis(limit: 2)
        #expect(ids.count == 2)
    }

    @Test func insightDraftClampsOutOfRangeConfidence() {
        let tooHigh = InsightDraft(summary: "s", mood: .neutral, moodConfidence: 5.0, modelIdentifier: "m")
        #expect(tooHigh.moodConfidence == 1.0)

        let tooLow = InsightDraft(summary: "s", mood: .neutral, moodConfidence: -3.0, modelIdentifier: "m")
        #expect(tooLow.moodConfidence == 0.0)

        let inRange = InsightDraft(summary: "s", mood: .neutral, moodConfidence: 0.42, modelIdentifier: "m")
        #expect(inRange.moodConfidence == 0.42)
    }
}
