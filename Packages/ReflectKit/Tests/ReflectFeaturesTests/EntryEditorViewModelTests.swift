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
}
