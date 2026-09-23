import Foundation
import SwiftData
import ReflectDomain

/// Whether the last edit is saved, pending a debounced save, or brand new.
enum SaveState: Equatable {
    case idle
    case pending
    case saved(Date)
    case failed
}

/// The write path for the editor. Keeping save/debounce logic here (rather than in the
/// view) makes it testable without a UI test target.
@Observable
final class EntryEditorViewModel {
    var text: String = ""
    private(set) var stats: TextStats = TextStats("")
    private(set) var saveState: SaveState = .idle
    /// Set the first time the user actually edits `text` (as opposed to `load()` populating
    /// it). The view uses this to skip the debounced write that would otherwise fire once on
    /// appear with unchanged text.
    private(set) var hasEdited = false
    /// Set when `load()`'s fetch throws for an `.edit` entry. `flush()` refuses to write
    /// while this is set, so a transient read failure can never overwrite/delete the user's
    /// existing entry with the empty text the failed load left behind.
    private(set) var loadFailed = false
    /// Invoked when `finish()` (the flush that runs on dismiss, from `.onDisappear`) ends in
    /// `.failed`. `finish()` fires after the editor has already left the screen, so its own
    /// `saveState` can never be rendered by the footer that's being torn down with it; the
    /// presenting view wires this closure to an `.alert` that outlives the sheet.
    var onFinishFailure: (() -> Void)?
    /// Invoked at the end of `flush()`, only on the `.saved` path with non-blank text, so the
    /// view can hand the entry off for enrichment. Enrichment is entirely downstream of
    /// saving: `flush()` still reports `.saved` when this is `nil`, and no failure here can
    /// ever affect `saveState`.
    var onSaved: ((UUID, String) -> Void)?

    private let mode: EditorMode
    private let context: ModelContext
    private(set) var entryID: UUID?

    init(mode: EditorMode, context: ModelContext) {
        self.mode = mode
        self.context = context
        if case .edit(let id) = mode {
            self.entryID = id
        }
    }

    /// For `.edit(id)`, fetches and populates `text`. For `.new`, leaves everything empty
    /// and creates no row yet. An entry that is legitimately gone (fetch succeeds, returns
    /// nil) is not a load failure: `flush()`'s own lookup will also miss it and safely no-op.
    func load() {
        guard case .edit(let id) = mode else { return }
        var descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate<JournalEntry> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            if let entry = try context.fetch(descriptor).first {
                text = entry.text
                stats = TextStats(entry.text)
            }
        } catch {
            loadFailed = true
        }
    }

    func textChanged() {
        hasEdited = true
        stats = TextStats(text)
        saveState = .pending
    }

    /// The debounced write. Deliberately does **not** delete an existing row on blank text:
    /// the row (and its `id`/`createdAt`/`source`) must stay alive for the whole editor
    /// session so a clear-and-retype gesture keeps editing the same entry rather than
    /// silently replacing it with a new one. Only `finish()`, called once on dismiss, deletes
    /// an entry that is still empty when the editor closes.
    func flush() {
        guard !loadFailed else {
            saveState = .failed
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A brand-new entry with nothing typed yet: nothing to write.
        if trimmed.isEmpty && entryID == nil {
            return
        }

        do {
            if let entryID {
                guard let entry = try fetchEntry(id: entryID) else {
                    // The row is gone (e.g. deleted elsewhere while the editor was still
                    // open). Distinguish this from a *thrown* fetch below: both are
                    // unrecoverable from here, so both report `.failed` rather than silently
                    // dropping the typed text with the footer still reading "Saving…".
                    saveState = .failed
                    return
                }
                entry.touch(text: text)
            } else {
                let entry = JournalEntry(text: text)
                context.insert(entry)
                entryID = entry.id
            }
            try context.save()
            saveState = .saved(.now)
            // `hasEdited`: a pure open-and-close of an existing entry (nothing typed) must not
            // hand the entry off for enrichment — that would cost a full on-device generation
            // for a no-op read, and (before this guard) the accompanying `entry.touch(text:)`
            // above would also have bumped `updatedAt` past the insight's `generatedAt`,
            // marking an already-current insight stale for the next launch's sweep.
            if let entryID, !trimmed.isEmpty, hasEdited {
                onSaved?(entryID, text)
            }
        } catch {
            saveState = .failed
        }
    }

    /// Called once on dismiss (from `.onDisappear`, which fires for every dismissal path —
    /// `Done`, `Close` and interactive swipe-down alike): flushes so nothing typed in the
    /// last debounce window is lost, then deletes the row if it is still blank so an emptied
    /// entry never lingers in the list.
    func finish() {
        // Skip the flush entirely for a pure open-and-close of an existing entry: nothing was
        // typed, so there is nothing new to write, and calling `flush()` anyway would call
        // `entry.touch(text:)` and move `updatedAt` for no reason, marking an up-to-date
        // insight stale for the next launch's sweep. `loadFailed` is the one exception — flush
        // still runs so that a failed load is still reported through `onFinishFailure` even if
        // the user never touched the (empty, because the load failed) text.
        if hasEdited || loadFailed {
            flush()
        }
        if case .failed = saveState {
            onFinishFailure?()
            return
        }

        guard let entryID else { return }
        do {
            guard let entry = try fetchEntry(id: entryID) else { return }
            guard entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            context.delete(entry)
            try context.save()
            self.entryID = nil
        } catch {
            saveState = .failed
            onFinishFailure?()
        }
    }

    private func fetchEntry(id: UUID) throws -> JournalEntry? {
        var descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate<JournalEntry> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
