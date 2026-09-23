import SwiftUI
import ReflectDomain
import ReflectIntelligence

/// Composition helper so the app target's composition root can wire up enrichment without
/// importing `ReflectIntelligence` itself — CLAUDE.md restricts the app target to
/// `ReflectDomain` and `ReflectFeatures`. A bare factory function returning `EnrichmentCoordinator`
/// would not be enough on its own: the app target would still need to spell
/// `EnrichmentCoordinator` to declare a stored property of that type, which would force the
/// very import this exists to avoid. Wrapping construction *and* environment injection behind
/// this opaque type means the app target never needs to name `EnrichmentCoordinator` at all.
public struct AppIntelligence: Sendable {
    private let coordinator: EnrichmentCoordinator

    /// Builds the concrete `IntelligenceEngine` analyzer and the coordinator that owns it.
    public init(store: JournalStore) {
        self.coordinator = EnrichmentCoordinator(store: store, analyzer: IntelligenceEngine())
    }

    /// Injects the coordinator into `view`'s environment, mirroring `.environment(\.journalStore, store)`
    /// at the call site without requiring the caller to import `ReflectIntelligence`.
    public func inject(into view: some View) -> some View {
        view.environment(\.enrichmentCoordinator, coordinator)
    }
}
