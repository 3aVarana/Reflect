import SwiftUI
import SwiftData
import ReflectDomain

/// Which sheet the editor should present, and over what entry.
enum EditorMode: Identifiable, Hashable {
    case new
    case edit(UUID)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): "edit-\(id)"
        }
    }
}

/// The Journal tab: an adaptive split view (sidebar list + detail) that collapses to a
/// stack on compact width, so iPhone gets push navigation and iPad gets a side-by-side
/// layout with no `horizontalSizeClass` branching.
struct JournalTabView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var selectedEntryID: UUID?
    @State private var editorMode: EditorMode?
    @State private var saveErrorMessage: String?

    var body: some View {
        NavigationSplitView {
            JournalListView(searchText: searchText, selection: $selectedEntryID)
                .searchable(text: $searchText, prompt: Text("Search entries", bundle: .module))
                .navigationTitle(Text("Reflect", bundle: .module))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editorMode = .new
                        } label: {
                            Label {
                                Text("New entry", bundle: .module)
                            } icon: {
                                Image(systemName: "square.and.pencil")
                            }
                        }
                    }
                }
        } detail: {
            if let selectedEntryID {
                EntryDetailView(entryID: selectedEntryID)
            } else {
                ContentUnavailableView(
                    String(localized: "Select an entry", bundle: .module),
                    systemImage: "book.closed",
                    description: Text("Choose an entry from the list, or start a new one.", bundle: .module)
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
}

#Preview {
    JournalTabView()
        .modelContainer(try! ReflectModelContainer.makeInMemory())
}
