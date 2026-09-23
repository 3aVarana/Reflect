import SwiftUI
import SwiftData
import ReflectDomain

/// Top-level navigation: three tabs, each a self-contained feature. The app target injects
/// the model container and `JournalStore` through the environment.
public struct ReflectRootView: View {
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
    }
}

#Preview {
    ReflectRootView()
        .modelContainer(try! ReflectModelContainer.makeInMemory())
}
