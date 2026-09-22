import SwiftUI
import SwiftData
import ReflectDomain
import ReflectIntelligence

/// Top-level navigation. Real feature screens replace the placeholders phase by phase.
public struct ReflectRootView: View {
    @Query(sort: \JournalEntry.createdAt, order: .reverse) private var entries: [JournalEntry]

    public init() {}

    public var body: some View {
        TabView {
            Tab("Journal", systemImage: "book.closed") {
                NavigationStack {
                    List(entries) { entry in
                        Text(entry.text)
                            .lineLimit(2)
                    }
                    .overlay {
                        if entries.isEmpty {
                            ContentUnavailableView(
                                "No entries yet",
                                systemImage: "square.and.pencil",
                                description: Text("Your first reflection will appear here.")
                            )
                        }
                    }
                    .navigationTitle("Reflect")
                }
            }
            Tab("Insights", systemImage: "sparkles") {
                NavigationStack {
                    ContentUnavailableView(
                        "Insights",
                        systemImage: "sparkles",
                        description: Text(IntelligenceAvailability.current.message)
                    )
                    .navigationTitle("Insights")
                }
            }
        }
    }
}

#Preview {
    ReflectRootView()
        .modelContainer(try! ReflectModelContainer.makeInMemory())
}
