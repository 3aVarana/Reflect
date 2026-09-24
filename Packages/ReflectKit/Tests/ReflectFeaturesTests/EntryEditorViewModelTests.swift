import Testing
import Foundation
import SwiftData
import ReflectDomain
@testable import ReflectFeatures

struct EntryEditorViewModelTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ReflectModelContainer.makeInMemory())
    }

    @Test func newWithBlankTextAndFinishInsertsZeroRows() throws {
        let context = try makeContext()
        let vm = EntryEditorViewModel(mode: .new, context: context)
        vm.load()
        vm.finish()

        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        #expect(entries.isEmpty)
    }

    @Test func newWithTextAndFlushInsertsExactlyOneRow() throws {
        let context = try makeContext()
        let vm = EntryEditorViewModel(mode: .new, context: context)
        vm.load()
        vm.text = "hello"
        vm.textChanged()
        vm.flush()

        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        #expect(entries.count == 1)
        #expect(entries.first?.text == "hello")
    }

    @Test func secondFlushAfterEditingUpdatesSameRowAndAdvancesUpdatedAt() throws {
        let context = try makeContext()
        let vm = EntryEditorViewModel(mode: .new, context: context)
        vm.load()
        vm.text = "hello"
        vm.textChanged()
        vm.flush()

        let entries1 = try context.fetch(FetchDescriptor<JournalEntry>())
        let first = try #require(entries1.first)
        let firstUpdatedAt = first.updatedAt

        vm.text = "hello world"
        vm.textChanged()
        vm.flush()

        let entries2 = try context.fetch(FetchDescriptor<JournalEntry>())
        #expect(entries2.count == 1)
        let second = try #require(entries2.first)
        #expect(second.text == "hello world")
        #expect(second.updatedAt > firstUpdatedAt)
    }

    @Test func editModeLoadPopulatesTextFromStore() throws {
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()

        #expect(vm.text == "Existing text")
    }

    @Test func editModeLoadExposesThePersistedInsightAsAValue() throws {
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        let insight = EntryInsight(
            summary: "A stored summary",
            reflectionQuestion: "A stored question",
            mood: .great,
            moodConfidence: 0.9,
            modelIdentifier: "test"
        )
        context.insert(entry)
        context.insert(insight)
        entry.insight = insight
        entry.mood = .great
        try context.save()

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()

        #expect(vm.persistedInsight?.summary == "A stored summary")
        #expect(vm.persistedInsight?.reflectionQuestion == "A stored question")
        #expect(vm.persistedInsight?.mood == .great)
    }

    @Test func editModeLoadLeavesPersistedInsightNilForAnUnanalysedEntry() throws {
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()

        #expect(vm.persistedInsight == nil)
    }

    @Test func newModeNeverHasAPersistedInsight() throws {
        let vm = EntryEditorViewModel(mode: .new, context: try makeContext())
        vm.load()
        #expect(vm.persistedInsight == nil)
    }

    @Test func editModeClearedToEmptyAndFinishDeletesRow() throws {
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()
        vm.text = ""
        vm.textChanged()
        vm.finish()

        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        #expect(entries.isEmpty)
    }

    @Test func statsWordsTracksTextChanged() throws {
        let context = try makeContext()
        let vm = EntryEditorViewModel(mode: .new, context: context)
        vm.load()

        #expect(vm.stats.words == 0)

        vm.text = "one two three"
        vm.textChanged()

        #expect(vm.stats.words == 3)
    }

    @Test func flushOnBlankTextOverExistingRowKeepsRowAlive() throws {
        // Regression test: flush() (the debounced write, distinct from finish()) must NOT
        // delete an existing row on blank text — the row's identity must survive for the
        // whole editor session so a subsequent retype edits the same entry rather than
        // inserting a new one under a different id/createdAt. Only finish() (on dismiss)
        // deletes a row that is still blank when the editor closes.
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()
        let originalID = entry.id

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()
        vm.text = "   "
        vm.textChanged()
        vm.flush()

        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        #expect(entries.count == 1)
        #expect(entries.first?.id == originalID)
    }

    @Test func editClearAndRetypeUpdatesSameRowPreservingIdentity() throws {
        // Regression test for the critical review finding: clearing an existing entry's text
        // mid-session and then retyping must keep editing the *same* row — same id and
        // createdAt — rather than silently deleting it and inserting a new one.
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()
        let originalID = entry.id
        let originalCreatedAt = entry.createdAt

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()

        vm.text = ""
        vm.textChanged()
        vm.flush()

        vm.text = "new content"
        vm.textChanged()
        vm.flush()

        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        #expect(entries.count == 1)
        let survivor = try #require(entries.first)
        #expect(survivor.id == originalID)
        #expect(survivor.createdAt == originalCreatedAt)
        #expect(survivor.text == "new content")
    }

    @Test func flushWithRowDeletedElsewhereReportsFailedRatherThanDroppingText() throws {
        // Warning fix: if entryID is set but the row is gone (deleted from another context
        // while the editor was open), flush() must not silently return leaving `saveState`
        // stuck at `.pending` with the typed text dropped — it should report `.failed`.
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()

        context.delete(entry)
        try context.save()

        vm.text = "new content"
        vm.textChanged()
        vm.flush()

        #expect(vm.saveState == .failed)
    }

    @Test func finishFailureInvokesOnFinishFailureCallback() throws {
        // Warning fix: a failure that only surfaces during the final `finish()` flush (which
        // runs from `.onDisappear`, after the editor has already left the screen) must be
        // reported through a channel that outlives the torn-down footer.
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()

        context.delete(entry)
        try context.save()

        var failureReported = false
        vm.onFinishFailure = { failureReported = true }

        vm.text = "new content"
        vm.textChanged()
        vm.finish()

        #expect(vm.saveState == .failed)
        #expect(failureReported)
    }

    @Test func onSavedFiresExactlyOnceWithTheEntryIDAndCurrentTextOnASuccessfulFlush() throws {
        let context = try makeContext()
        let vm = EntryEditorViewModel(mode: .new, context: context)
        vm.load()

        var calls: [(id: UUID, text: String)] = []
        vm.onSaved = { id, text in calls.append((id, text)) }

        vm.text = "hello"
        vm.textChanged()
        vm.flush()

        #expect(calls.count == 1)
        #expect(calls.first?.text == "hello")
        #expect(calls.first?.id == vm.entryID)
    }

    @Test func onSavedDoesNotFireForBlankText() throws {
        // Regression: flush() on blank text over an existing row still reports `.saved` (the
        // row is kept alive), but that must not be treated as something worth enqueueing for
        // enrichment.
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()

        var callCount = 0
        vm.onSaved = { _, _ in callCount += 1 }

        vm.text = "   "
        vm.textChanged()
        vm.flush()

        if case .saved = vm.saveState {
            // expected: flush() on blank text over an existing row still reports .saved.
        } else {
            Issue.record("Expected saveState to be .saved, was \(vm.saveState)")
        }
        #expect(callCount == 0)
    }

    @Test func flushStillReportsSavedWhenOnSavedIsNil() throws {
        // Enrichment must never gate saving: with no `onSaved` handler at all, flush() still
        // succeeds and inserts exactly one row.
        let context = try makeContext()
        let vm = EntryEditorViewModel(mode: .new, context: context)
        vm.load()
        #expect(vm.onSaved == nil)

        vm.text = "hello"
        vm.textChanged()
        vm.flush()

        if case .saved = vm.saveState {
            // expected
        } else {
            Issue.record("Expected saveState to be .saved, was \(vm.saveState)")
        }
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        #expect(entries.count == 1)
    }

    @Test func hasEditedStaysFalseUntilTextChangedIsCalled() throws {
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        vm.load()
        #expect(vm.hasEdited == false)

        vm.text = "Existing text edited"
        vm.textChanged()
        #expect(vm.hasEdited == true)
    }

    @Test func openingAnExistingEntryAndFinishingWithoutTypingDoesNotEnqueueOrBumpUpdatedAt() throws {
        // Regression for the `hasEdited` guard's actual *consequence*, not just the flag:
        // `hasEditedStaysFalseUntilTextChangedIsCalled` above only pins `hasEdited` itself, so
        // nothing would fail if a future change re-added an unguarded `onSaved?` call or
        // dropped `if hasEdited || loadFailed` in `finish()`. A pure open-and-close of an
        // existing entry (load, then finish, with nothing typed) must not call `onSaved` and
        // must not move `updatedAt` — either would cost a needless generation and re-stale an
        // already-current insight for the next launch's sweep.
        let context = try makeContext()
        let entry = JournalEntry(text: "Existing text")
        context.insert(entry)
        try context.save()
        let originalUpdatedAt = entry.updatedAt

        let vm = EntryEditorViewModel(mode: .edit(entry.id), context: context)
        var onSavedCallCount = 0
        vm.onSaved = { _, _ in onSavedCallCount += 1 }

        vm.load()
        vm.finish()

        #expect(onSavedCallCount == 0)
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let reloaded = try #require(entries.first)
        #expect(reloaded.updatedAt == originalUpdatedAt)
    }
}
