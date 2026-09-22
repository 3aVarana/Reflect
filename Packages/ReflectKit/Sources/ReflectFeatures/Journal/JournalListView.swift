import SwiftUI
import SwiftData
import ReflectDomain

/// The Journal sidebar: entries grouped by day, newest first, with search and swipe-to-delete.
struct JournalListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [JournalEntry]
    @Binding private var selection: UUID?
    private let searchText: String

    @State private var deleteErrorMessage: String?

    init(searchText: String, selection: Binding<UUID?>) {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.searchText = searchText
        _entries = Query(
            filter: #Predicate<JournalEntry> { q.isEmpty || $0.text.localizedStandardContains(q) },
            sort: [SortDescriptor(\JournalEntry.createdAt, order: .reverse)]
        )
        _selection = selection
    }

    /// Groups the live `entries` by calendar day, computed fresh inside `body` on every
    /// render (not cached, no `.onChange`) so SwiftUI's Observation tracking — which
    /// `EntryRow` relies on to stay live after an in-place edit — stays intact. Deliberately
    /// does not go through `EntrySnapshot`/`groupedByDay`: those project `insight`, `themes`
    /// and `actionItems` per entry, none of which the row displays (it reads `mood`, `text`,
    /// `createdAt` and `source` straight off the model), so grouping directly over
    /// `JournalEntry.createdAt` here also avoids the relationship faulting the cycle-1 review
    /// warned about, rather than merely re-adding it in a different form.
    private var sections: [(day: Date, entries: [JournalEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.createdAt) }
        return grouped
            .map { day, dayEntries in
                (day: day, entries: dayEntries.sorted { $0.createdAt > $1.createdAt })
            }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(sections, id: \.day) { section in
                Section(DayTitleFormatter.title(for: section.day)) {
                    ForEach(section.entries, id: \.id) { entry in
                        EntryRow(entry: entry)
                            .tag(entry.id)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(entry.id)
                                } label: {
                                    Label {
                                        Text("Delete", bundle: .module)
                                    } icon: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                    }
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        String(localized: "No entries yet", bundle: .module),
                        systemImage: "square.and.pencil",
                        description: Text("Your first reflection will appear here.", bundle: .module)
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
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
    }

    private func delete(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if selection == id {
            selection = nil
        }
        modelContext.delete(entry)
        do {
            try modelContext.save()
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }
}

#Preview {
    let container = try! ReflectModelContainer.makeInMemory()
    let context = ModelContext(container)
    context.insert(JournalEntry(text: "First reflection of the day."))
    context.insert(JournalEntry(text: "A second entry, from yesterday.", source: .voice))
    try? context.save()

    return NavigationStack {
        JournalListView(searchText: "", selection: .constant(nil))
    }
    .modelContainer(container)
}
