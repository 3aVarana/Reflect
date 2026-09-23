import Testing
import Foundation
import SwiftData
import ReflectDomain
@testable import ReflectIntelligence

/// Warning fixes (fix cycle 2): the supersede-cancel test built on `StreamAnalyzer` (proving the
/// stale run is actually stopped, not just that `GatedAnalyzer`'s pre-fix behaviour is pinned),
/// and the injectable `availability` seam on `EnrichmentCoordinator.init` that lets the
/// `.unknown -> .modelUnavailable` remap in `process` be exercised deterministically instead of
/// depending on the build host's real Apple Intelligence state. Split into its own file,
/// alongside `EnrichmentCoordinatorTests` and `EnrichmentCoordinatorCancellationTests`, purely to
/// keep all three files under SwiftLint's file/type-length thresholds.
struct EnrichmentCoordinatorAvailabilityTests {
    private func makeStore() throws -> (container: ModelContainer, store: JournalStore) {
        let container = try ReflectModelContainer.makeInMemory()
        return (container, JournalStore(modelContainer: container))
    }

    /// Injected so tests never actually sleep during a retry backoff.
    private func noDelay(_ attempt: Int) async {}

    /// Subscribes fresh and collects every update up to and including the first terminal one.
    /// See `EnrichmentCoordinatorTests`' matching helper for why this is unsafe for tests that
    /// need the *complete* sequence rather than just the final state.
    private func collectUntilTerminal(
        _ coordinator: EnrichmentCoordinator,
        entryID: UUID
    ) async -> [EnrichmentCoordinator.EnrichmentUpdate] {
        await collectUntilTerminal(stream: await coordinator.updates(for: entryID))
    }

    private func collectUntilTerminal(
        stream: AsyncStream<EnrichmentCoordinator.EnrichmentUpdate>
    ) async -> [EnrichmentCoordinator.EnrichmentUpdate] {
        var collected: [EnrichmentCoordinator.EnrichmentUpdate] = []
        for await update in stream {
            collected.append(update)
            switch update {
            case .finished, .failed:
                return collected
            case .queued, .analyzing:
                continue
            }
        }
        return collected
    }

    @Test func supersedingAnInFlightRunProducesNoFinishedForTheStaleRunAndPersistsNothingFromIt() async throws {
        // `EnrichmentCoordinatorTests.enqueueingSameIDWithNewTextSupersedesAndAnalyzesNewerText`
        // asserts the *pre-fix* behaviour (both generations complete), because its
        // `GatedAnalyzer` cannot observe task cancellation. `StreamAnalyzer` (from
        // `EnrichmentCoordinatorCancellationTests`) does, so this pins the actual fix: the stale
        // ("Original text") run must never reach `.finished` and must never persist an insight,
        // and cancelling it must not stop the superseding ("Newer text") run from completing.
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Original text")
        let analyzer = StreamAnalyzer()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        let stream = await coordinator.updates(for: entry.id)
        await coordinator.enqueue(entryID: entry.id, text: "Original text")
        await analyzer.waitUntilReady()

        await coordinator.enqueue(entryID: entry.id, text: "Newer text")

        // At this point the stale run's analyzer stream has never yielded anything, so nothing
        // could have been persisted from it yet — regardless of exactly when its cancellation is
        // observed.
        let snapshotBeforeTheSupersedingRunCompletes = try await store.snapshot(id: entry.id)
        #expect(snapshotBeforeTheSupersedingRunCompletes?.summary == nil)

        // Let the superseding run actually finish so the drain loop terminates cleanly instead
        // of leaving the coordinator suspended forever.
        await analyzer.waitUntilReady(count: 2)
        let result = AnalysisResult(
            mood: .good,
            moodConfidence: 0.5,
            summary: "Newer summary",
            reflectionQuestion: nil,
            isPartialText: false,
            modelIdentifier: "stream-test-analyzer"
        )
        await analyzer.finishLatest(with: result)

        let updates = await collectUntilTerminal(stream: stream)
        // The first *terminal* update on this stream is asserted to be the superseding run's
        // `.finished`: if the stale run had ever broadcast anything (a regression of the fix),
        // `collectUntilTerminal` would have returned on that instead.
        guard case .finished(let draft) = updates.last else {
            Issue.record("Expected the superseding run to finish, got \(String(describing: updates.last))")
            return
        }
        #expect(draft.summary == "Newer summary")

        let snapshot = try await store.snapshot(id: entry.id)
        #expect(snapshot?.summary == "Newer summary")
    }

    @Test func unknownErrorBecomesModelUnavailableWithNoRetryWhenInjectedAvailabilityIsNotAvailable() async throws {
        // `process`'s `.unknown -> .modelUnavailable` remap used to read the global
        // `IntelligenceAvailability.current`, making it untestable without depending on the
        // build host's real Apple Intelligence state. `availability` is now injected so this
        // branch is reachable from a test deterministically.
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Unavailable host")
        let analyzer = FakeEntryAnalyzer(script: [.failure(.unknown)])
        let coordinator = EnrichmentCoordinator(
            store: store,
            analyzer: analyzer,
            maxAttempts: 3,
            retryDelay: noDelay,
            availability: { .appleIntelligenceNotEnabled }
        )

        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        let updates = await collectUntilTerminal(coordinator, entryID: entry.id)

        #expect(updates.last == .failed(.modelUnavailable))
        // Demoted straight to a non-retryable answer: no second generation attempt.
        let recorded = await analyzer.recordedTexts()
        #expect(recorded.count == 1)
    }

    @Test func unknownErrorIsRetriedNormallyWhenInjectedAvailabilityIsAvailable() async throws {
        // The other half of the seam above: when availability genuinely is `.available`, an
        // `.unknown` error is not demoted and follows the ordinary retry policy.
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Available host")
        let analyzer = FakeEntryAnalyzer(script: [.failure(.unknown), .failure(.unknown)])
        let coordinator = EnrichmentCoordinator(
            store: store,
            analyzer: analyzer,
            maxAttempts: 2,
            retryDelay: noDelay,
            availability: { .available }
        )

        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        let updates = await collectUntilTerminal(coordinator, entryID: entry.id)

        #expect(updates.last == .failed(.unknown))
        let recorded = await analyzer.recordedTexts()
        #expect(recorded.count == 2)
    }
}
