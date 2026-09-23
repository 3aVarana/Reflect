import SwiftUI
import ReflectIntelligence

extension EnvironmentValues {
    /// Optional for the same reason `journalStore` is (see `JournalStoreEnvironment.swift`):
    /// there is no sensible default without a `JournalStore` to build one from. Consumers
    /// `guard let` and render a non-crashing state when `nil` (previews, tests, Settings-only
    /// contexts).
    @Entry public var enrichmentCoordinator: EnrichmentCoordinator?
}
