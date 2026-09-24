import SwiftUI
import SwiftData
import ReflectDomain

/// The read surface for a single entry. Stays live after an edit via `@Query`; shows a
/// placeholder if the entry is gone (e.g. deleted from another column on iPad).
struct EntryDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var entries: [JournalEntry]
    @State private var editorMode: EditorMode?
    @State private var isShowingDeleteConfirmation = false
    @State private var deleteErrorMessage: String?
    @State private var saveErrorMessage: String?

    private let entryID: UUID

    init(entryID: UUID) {
        self.entryID = entryID
        _entries = Query(filter: #Predicate<JournalEntry> { $0.id == entryID })
    }

    private var entry: JournalEntry? { entries.first }

    var body: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        HStack(spacing: Spacing.s) {
                            MoodGlyph(mood: entry.mood, size: .title2)
                            Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.text)
                            .font(.body)
                            .textSelection(.enabled)
                        InsightPanel(
                            entryID: entryID,
                            insight: entry.insight.map(InsightDraft.init),
                            text: entry.text
                        )
                            // Forces a brand-new `InsightPanel` (and therefore a brand-new
                            // `InsightPanelModel`) whenever the entry changes — e.g. selecting
                            // a different row in the iPad split view's detail column, which
                            // reuses this view's identity across selections. Without this,
                            // `InsightPanel`'s `@State private var model` is "first instance
                            // wins": it would stay pinned to whichever `entryID` it first saw,
                            // silently rendering (and, on "Re-analyze", overwriting) the wrong
                            // entry. See the critical review finding this documents.
                            .id(entryID)
                    }
                    .padding(Spacing.l)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editorMode = .edit(entryID)
                        } label: {
                            Label {
                                Text("Edit", bundle: .module)
                            } icon: {
                                Image(systemName: "pencil")
                            }
                        }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            isShowingDeleteConfirmation = true
                        } label: {
                            Label {
                                Text("Delete", bundle: .module)
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .confirmationDialog(
                    String(localized: "Delete this entry?", bundle: .module),
                    isPresented: $isShowingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                        delete(entry)
                    }
                    Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
                }
            } else {
                ContentUnavailableView(
                    String(localized: "Entry not found", bundle: .module),
                    systemImage: "questionmark.folder",
                    description: Text("This entry may have been deleted.", bundle: .module)
                )
            }
        }
        .sheet(item: $editorMode) { mode in
            EntryEditorView(mode: mode, context: modelContext) {
                saveErrorMessage = String(
                    localized: "The last change to this entry couldn't be saved.",
                    bundle: .module
                )
            }
        }
        .alert(
            String(localized: "Couldn't delete entry", bundle: .module),
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { isPresented in if !isPresented { deleteErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .alert(
            String(localized: "Couldn't save entry", bundle: .module),
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in if !isPresented { saveErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private func delete(_ entry: JournalEntry) {
        modelContext.delete(entry)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }
}

#Preview {
    let container = try! ReflectModelContainer.makeInMemory()
    let context = ModelContext(container)
    let entry = JournalEntry(text: "A longer reflection about the day, written for the detail preview.")
    entry.mood = .good
    context.insert(entry)
    try? context.save()

    return NavigationStack {
        EntryDetailView(entryID: entry.id)
    }
    .modelContainer(container)
}
