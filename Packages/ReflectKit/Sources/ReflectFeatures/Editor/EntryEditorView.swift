import SwiftUI
import SwiftData
import ReflectDomain

/// The full-screen text editor. Autosaves on a 1s debounce after typing stops, and always
/// flushes/cleans up on dismiss.
struct EntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var vm: EntryEditorViewModel

    private let mode: EditorMode

    /// The view model is built here, from a `ModelContext` handed in by the presenter,
    /// rather than lazily in `.onAppear`. An `.onAppear` attached to a container whose only
    /// child is `if let vm { … }` never fires while `vm` is nil (there is nothing on screen
    /// to appear), which left the sheet permanently blank on device. Building the model
    /// eagerly means the editor has no empty state at all.
    ///
    /// `onSaveFailure` is invoked if the very last flush (from `.onDisappear`) fails. That
    /// failure can never be rendered in this view's own footer — the sheet is already gone by
    /// the time it happens — so the presenter wires this to an `.alert` of its own that
    /// outlives the sheet.
    init(mode: EditorMode, context: ModelContext, onSaveFailure: (() -> Void)? = nil) {
        self.mode = mode
        let vm = EntryEditorViewModel(mode: mode, context: context)
        vm.onFinishFailure = onSaveFailure
        vm.load()
        _vm = State(initialValue: vm)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: Binding(
                get: { vm.text },
                set: { vm.text = $0; vm.textChanged() }
            ))
            .scrollContentBackground(.hidden)
            .padding(Spacing.m)
            .focused($isFocused)
            .safeAreaInset(edge: .bottom) {
                footer(vm)
            }
            .task(id: vm.text) {
                guard vm.hasEdited else { return }
                try? await Task.sleep(for: .seconds(1.0))
                guard !Task.isCancelled else { return }
                vm.flush()
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", bundle: .module)) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", bundle: .module)) {
                        isFocused = false
                    }
                }
            }
            .onAppear {
                isFocused = true
            }
        }
        // Fires for every dismissal path — `Done`, `Close`, and interactive swipe-down —
        // so the final debounce window is never lost and an emptied entry never lingers.
        // This is the single source of truth for "leaving the editor"; the toolbar
        // buttons only ever call `dismiss()`.
        .onDisappear {
            vm.finish()
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .new: String(localized: "New entry", bundle: .module)
        case .edit: String(localized: "Edit entry", bundle: .module)
        }
    }

    @ViewBuilder
    private func footer(_ vm: EntryEditorViewModel) -> some View {
        HStack {
            Text("\(vm.stats.words) words", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            saveStateLabel(vm.saveState)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.s)
    }

    @ViewBuilder
    private func saveStateLabel(_ state: SaveState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .pending:
            Text("Saving…", bundle: .module)
        case .saved:
            Text("Saved", bundle: .module)
        case .failed:
            Text("Couldn't save", bundle: .module)
                .foregroundStyle(.red)
        }
    }
}

#Preview("New entry") {
    let container = try! ReflectModelContainer.makeInMemory()
    return EntryEditorView(mode: .new, context: ModelContext(container))
        .modelContainer(container)
}

#Preview("Edit entry") {
    let container = try! ReflectModelContainer.makeInMemory()
    let context = ModelContext(container)
    let entry = JournalEntry(text: "An entry being edited.")
    context.insert(entry)
    try? context.save()

    return EntryEditorView(mode: .edit(entry.id), context: context)
        .modelContainer(container)
}
