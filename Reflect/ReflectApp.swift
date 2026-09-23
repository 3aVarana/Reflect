import SwiftUI
import SwiftData
import ReflectDomain
import ReflectFeatures

@main
struct ReflectApp: App {
    private let container: ModelContainer
    private let store: JournalStore

    init() {
        do {
            container = try ReflectModelContainer.make()
        } catch {
            fatalError("Unable to open the journal store: \(error)")
        }
        store = JournalStore(modelContainer: container)
    }

    var body: some Scene {
        WindowGroup {
            ReflectRootView()
                .environment(\.journalStore, store)
        }
        .modelContainer(container)
    }
}
