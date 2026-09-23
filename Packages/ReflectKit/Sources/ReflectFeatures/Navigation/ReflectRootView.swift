import SwiftUI
import SwiftData
import ReflectDomain
import ReflectIntelligence

/// Top-level navigation: three tabs, each a self-contained feature. The app target injects
/// the model container, `JournalStore` and `EnrichmentCoordinator` through the environment.
public struct ReflectRootView: View {
    @Environment(\.enrichmentCoordinator) private var coordinator

    public init() {}

    public var body: some View {
        TabView {
            Tab {
                JournalTabView()
            } label: {
                Label {
                    Text("Journal", bundle: .module)
                } icon: {
                    Image(systemName: "book.closed")
                }
            }
            Tab {
                InsightsPlaceholderView()
            } label: {
                Label {
                    Text("Insights", bundle: .module)
                } icon: {
                    Image(systemName: "sparkles")
                }
            }
            Tab {
                NavigationStack {
                    SettingsView()
                }
            } label: {
                Label {
                    Text("Settings", bundle: .module)
                } icon: {
                    Image(systemName: "gearshape")
                }
            }
        }
        // Gated on availability so an ineligible device never queues a doomed request for
        // every existing entry at launch.
        .task {
            guard IntelligenceAvailability.current == .available, let coordinator else { return }
            await coordinator.prewarm()
            await coordinator.enqueueStale()
        }
    }
}

#Preview {
    ReflectRootView()
        .modelContainer(try! ReflectModelContainer.makeInMemory())
}
