import SwiftUI
import SwiftData
import ReflectDomain
import ReflectFeatures

@main
struct ReflectApp: App {
    private let container: ModelContainer
    private let store: JournalStore
    // `AppIntelligence` is an opaque wrapper from `ReflectFeatures`: it owns the
    // `EnrichmentCoordinator` and injects it into the environment, so this composition root
    // never needs to name `EnrichmentCoordinator` (which lives in `ReflectIntelligence`) and
    // its import list stays exactly `ReflectDomain` + `ReflectFeatures`, per CLAUDE.md.
    private let intelligence: AppIntelligence

    init() {
        do {
            container = try ReflectModelContainer.make()
        } catch {
            fatalError("Unable to open the journal store: \(error)")
        }
        store = JournalStore(modelContainer: container)
        intelligence = AppIntelligence(store: store)
    }

    var body: some Scene {
        WindowGroup {
            intelligence.inject(into: ReflectRootView().environment(\.journalStore, store))
        }
        .modelContainer(container)
    }
}
