import SwiftUI
import SwiftData
import ReflectDomain
import ReflectFeatures

@main
struct ReflectApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ReflectModelContainer.make()
        } catch {
            fatalError("Unable to open the journal store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ReflectRootView()
        }
        .modelContainer(container)
    }
}
