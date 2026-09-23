import Foundation
import SwiftData

/// The single background read/write path for journal entries (ARCHITECTURE §4). Every
/// mutating method saves before returning; all inputs/outputs are `Sendable` snapshots so
/// SwiftData model objects never cross the actor boundary.
@ModelActor
public actor JournalStore {
    public func insert(
        text: String,
        source: EntrySource = .typed,
        createdAt: Date = .now
    ) throws -> EntrySnapshot {
        let entry = JournalEntry(createdAt: createdAt, text: text, source: source)
        modelContext.insert(entry)
        try modelContext.save()
        return EntrySnapshot(entry)
    }

    public func update(id: UUID, text: String, now: Date = .now) throws -> EntrySnapshot? {
        guard let entry = try entry(id: id) else { return nil }
        entry.touch(text: text, now: now)
        try modelContext.save()
        return EntrySnapshot(entry)
    }

    public func delete(id: UUID) throws -> Bool {
        guard let entry = try entry(id: id) else { return false }
        modelContext.delete(entry)
        try modelContext.save()
        return true
    }

    public func delete(ids: [UUID]) throws -> Int {
        var count = 0
        for id in ids {
            if let entry = try entry(id: id) {
                modelContext.delete(entry)
                count += 1
            }
        }
        try modelContext.save()
        return count
    }

    /// Wipes every table. `Theme` and `WeeklyDigest` rows are not reachable by cascade from
    /// `JournalEntry`, so they are deleted explicitly.
    ///
    /// Deletes row-by-row rather than via the batch `delete(model:)` form: batch deletes are
    /// a known SwiftData case that does not reliably merge into other live contexts (e.g. the
    /// main-actor context backing `@Query` in the journal list), which would leave the UI
    /// showing stale rows until relaunch.
    public func deleteAll() throws {
        for entry in try modelContext.fetch(FetchDescriptor<JournalEntry>()) {
            modelContext.delete(entry)
        }
        for theme in try modelContext.fetch(FetchDescriptor<Theme>()) {
            modelContext.delete(theme)
        }
        for digest in try modelContext.fetch(FetchDescriptor<WeeklyDigest>()) {
            modelContext.delete(digest)
        }
        try modelContext.save()
    }

    public func snapshot(id: UUID) throws -> EntrySnapshot? {
        try entry(id: id).map(EntrySnapshot.init)
    }

    public func snapshots(
        in range: DateRange? = nil,
        matching query: String? = nil,
        limit: Int? = nil
    ) throws -> [EntrySnapshot] {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = (trimmedQuery?.isEmpty ?? true) ? nil : trimmedQuery

        var descriptor: FetchDescriptor<JournalEntry>
        switch (range, q) {
        case let (.some(range), .some(q)):
            let start = range.start
            let end = range.end
            descriptor = FetchDescriptor<JournalEntry>(
                predicate: #Predicate<JournalEntry> {
                    $0.createdAt >= start && $0.createdAt < end && $0.text.localizedStandardContains(q)
                }
            )
        case let (.some(range), .none):
            let start = range.start
            let end = range.end
            descriptor = FetchDescriptor<JournalEntry>(
                predicate: #Predicate<JournalEntry> {
                    $0.createdAt >= start && $0.createdAt < end
                }
            )
        case let (.none, .some(q)):
            descriptor = FetchDescriptor<JournalEntry>(
                predicate: #Predicate<JournalEntry> {
                    $0.text.localizedStandardContains(q)
                }
            )
        case (.none, .none):
            descriptor = FetchDescriptor<JournalEntry>()
        }
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        if let limit {
            descriptor.fetchLimit = limit
        }
        return try modelContext.fetch(descriptor).map(EntrySnapshot.init)
    }

    public func moodTrend(
        in range: DateRange,
        calendar: Calendar = .current
    ) throws -> [MoodTrendPoint] {
        let start = range.start
        let end = range.end
        let descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate<JournalEntry> {
                $0.createdAt >= start && $0.createdAt < end
            }
        )
        let entries = try modelContext.fetch(descriptor)
        let withMood = entries.compactMap { entry -> (Date, Int)? in
            guard let mood = entry.mood else { return nil }
            return (calendar.startOfDay(for: entry.createdAt), mood.score)
        }
        let grouped = Dictionary(grouping: withMood, by: \.0)
        return grouped
            .map { day, values in
                let scores = values.map { Double($0.1) }
                let average = scores.reduce(0, +) / Double(scores.count)
                return MoodTrendPoint(day: day, averageScore: average, entryCount: scores.count)
            }
            .sorted { $0.day < $1.day }
    }

    public func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<JournalEntry>())
    }

    /// Persists an analysis result. Mutates the existing `EntryInsight` row in place when one
    /// already exists (rather than inserting a second row and orphaning the old one), and
    /// always denormalises `entry.mood` — the column the list glyph reads. Deliberately never
    /// touches `entry.updatedAt`: enrichment is not a user edit, and `idsNeedingAnalysis`
    /// compares `insight.generatedAt` against `entry.updatedAt` to detect staleness, so
    /// advancing `updatedAt` here would make every freshly-analyzed entry look stale again.
    public func applyInsight(entryID: UUID, draft: InsightDraft) throws -> EntrySnapshot? {
        guard let entry = try entry(id: entryID) else { return nil }
        if let insight = entry.insight {
            insight.summary = draft.summary
            insight.reflectionQuestion = draft.reflectionQuestion
            insight.mood = draft.mood
            insight.moodConfidence = draft.moodConfidence
            insight.analysisVersion = draft.analysisVersion
            insight.modelIdentifier = draft.modelIdentifier
            insight.generatedAt = draft.generatedAt
            insight.isPartial = draft.isPartial
        } else {
            let insight = EntryInsight(
                summary: draft.summary,
                reflectionQuestion: draft.reflectionQuestion,
                mood: draft.mood,
                moodConfidence: draft.moodConfidence,
                analysisVersion: draft.analysisVersion,
                modelIdentifier: draft.modelIdentifier,
                generatedAt: draft.generatedAt,
                isPartial: draft.isPartial
            )
            modelContext.insert(insight)
            entry.insight = insight
        }
        entry.mood = draft.mood
        try modelContext.save()
        return EntrySnapshot(entry)
    }

    /// Drops the entry's insight (if any) and clears the denormalised `mood` column. Used by
    /// "Re-analyze" and after a refusal, so a stale insight is never left next to text that
    /// now says something else.
    public func clearInsight(entryID: UUID) throws -> Bool {
        guard let entry = try entry(id: entryID) else { return false }
        if let insight = entry.insight {
            modelContext.delete(insight)
            entry.insight = nil
        }
        entry.mood = nil
        try modelContext.save()
        return true
    }

    /// Entries that need a fresh analysis pass: no insight yet, an insight from an older
    /// schema/prompt version, or an insight generated before the entry's last edit. Filtered
    /// in Swift rather than a `#Predicate` — predicates over an optional to-one relationship's
    /// properties are a known SwiftData trap, and this dataset is small enough that a Swift
    /// filter over an already-fetched array costs nothing worth optimising for.
    public func idsNeedingAnalysis(
        currentVersion: Int = AnalysisVersion.current,
        limit: Int? = nil
    ) throws -> [UUID] {
        var descriptor = FetchDescriptor<JournalEntry>()
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        let entries = try modelContext.fetch(descriptor)
        var ids: [UUID] = []
        for entry in entries {
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let needsAnalysis: Bool
            if let insight = entry.insight {
                needsAnalysis = insight.analysisVersion < currentVersion || insight.generatedAt < entry.updatedAt
            } else {
                needsAnalysis = true
            }
            guard needsAnalysis else { continue }
            ids.append(entry.id)
            if let limit, ids.count >= limit {
                break
            }
        }
        return ids
    }

    private func entry(id: UUID) throws -> JournalEntry? {
        var descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate<JournalEntry> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
