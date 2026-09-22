import Foundation
import SwiftData

/// Single place that knows the app's SwiftData schema.
public enum ReflectModelContainer {
    public static let schema = Schema([JournalEntry.self])

    /// The on-disk container used by the app.
    public static func make() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
    }

    /// An in-memory container for tests and previews.
    public static func makeInMemory() throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }
}
