import Testing
import Foundation
import SwiftData
import ReflectDomain
@testable import ReflectIntelligence

struct EnrichmentCoordinatorTests {
    private func makeStore() throws -> (container: ModelContainer, store: JournalStore) {
        let container = try ReflectModelContainer.makeInMemory()
        return (container, JournalStore(modelContainer: container))
    }

    /// Injected so tests never actually sleep during a retry backoff.
    private func noDelay(_ attempt: Int) async {}

    /// Subscribes fresh and collects every update up to and including the first terminal one
    /// (`.finished`/`.failed`). Only safe when the caller doesn't need every intermediate
    /// update captured: `updates(for:)` replays just the single most recent update to a late
    /// subscriber, so anything emitted before this call can be missed — fine for tests that
    /// only assert on the final state, not for tests asserting on the full sequence (see
    /// `collectUntilTerminal(stream:)` for those).
    private func collectUntilTerminal(
        _ coordinator: EnrichmentCoordinator,
        entryID: UUID
    ) async -> [EnrichmentCoordinator.EnrichmentUpdate] {
        await collectUntilTerminal(stream: await coordinator.updates(for: entryID))
    }

    /// Collects every update from an already-obtained stream up to and including the first
    /// terminal one. Callers that need the *complete* sequence must obtain `stream` via
    /// `coordinator.updates(for:)` before triggering the work that produces it.
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

    @Test func successfulRunPersistsInsightAndBroadcastsFinished() async throws {
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "A good day")
        let analyzer = FakeEntryAnalyzer.succeeding(mood: .great, summary: "You had a great day.")
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        let updates = await collectUntilTerminal(coordinator, entryID: entry.id)

        guard case .finished(let draft) = updates.last else {
            Issue.record("Expected .finished, got \(String(describing: updates.last))")
            return
        }
        #expect(draft.mood == .great)
        let snapshot = try await store.snapshot(id: entry.id)
        #expect(snapshot?.mood == .great)
    }

    @Test func twoEntriesAreProcessedInFIFOOrder() async throws {
        let (_, store) = try makeStore()
        let first = try await store.insert(text: "First", createdAt: .now)
        let second = try await store.insert(text: "Second", createdAt: .now.addingTimeInterval(1))
        let analyzer = FakeEntryAnalyzer.succeeding()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        await coordinator.enqueue(entryID: first.id, text: first.text)
        await coordinator.enqueue(entryID: second.id, text: second.text)
        _ = await collectUntilTerminal(coordinator, entryID: second.id)

        let recorded = await analyzer.recordedTexts()
        #expect(recorded == ["First", "Second"])
    }

    @Test func enqueueingSameIDAndTextTwiceAnalyzesOnce() async throws {
        let (container, store) = try makeStore()
        let entry = try await store.insert(text: "Same text")
        let analyzer = FakeEntryAnalyzer.succeeding()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        _ = await collectUntilTerminal(coordinator, entryID: entry.id)

        let recorded = await analyzer.recordedTexts()
        #expect(recorded.count == 1)

        let context = ModelContext(container)
        let insightRows = try context.fetch(FetchDescriptor<EntryInsight>())
        #expect(insightRows.count == 1)
    }

    @Test func enqueueingSameIDWithNewTextSupersedesAndAnalyzesNewerText() async throws {
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Original text")
        let analyzer = GatedAnalyzer()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        await coordinator.enqueue(entryID: entry.id, text: "Original text")
        // Wait until the analyzer has genuinely started the first (in-flight) call before
        // enqueuing the newer text, so this exercises the "supersede an in-flight run" branch
        // rather than a fresh append onto an as-yet-untouched queue.
        await analyzer.waitUntilStarted(count: 1)
        await coordinator.enqueue(entryID: entry.id, text: "Newer text")
        await analyzer.openGate()

        // The stale ("Original text") run finishes first, then the drain loop immediately
        // continues on to the superseding ("Newer text") item.
        _ = await collectUntilTerminal(coordinator, entryID: entry.id)
        await analyzer.waitUntilStarted(count: 2)
        _ = await collectUntilTerminal(coordinator, entryID: entry.id)

        let recorded = await analyzer.recordedTexts()
        #expect(recorded == ["Original text", "Newer text"])
    }

    @Test func retryableErrorIsRetriedUpToMaxAttemptsThenSucceeds() async throws {
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Retry me")
        let result = AnalysisResult(
            mood: .neutral,
            moodConfidence: 0.5,
            summary: "Recovered on retry",
            reflectionQuestion: nil,
            isPartialText: false,
            modelIdentifier: "test"
        )
        let analyzer = FakeEntryAnalyzer(script: [.failure(.throttled), .events([.finished(result)])])
        let coordinator = EnrichmentCoordinator(
            store: store,
            analyzer: analyzer,
            maxAttempts: 2,
            retryDelay: noDelay
        )

        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        let updates = await collectUntilTerminal(coordinator, entryID: entry.id)

        guard case .finished(let draft) = updates.last else {
            Issue.record("Expected .finished, got \(String(describing: updates.last))")
            return
        }
        #expect(draft.summary == "Recovered on retry")
        let recorded = await analyzer.recordedTexts()
        #expect(recorded.count == 2)
        let snapshot = try await store.snapshot(id: entry.id)
        #expect(snapshot?.summary == "Recovered on retry")
    }

    @Test func retryableErrorExhaustsMaxAttemptsThenReportsFailed() async throws {
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Always throttled")
        let analyzer = FakeEntryAnalyzer(script: [.failure(.throttled), .failure(.throttled)])
        let coordinator = EnrichmentCoordinator(
            store: store,
            analyzer: analyzer,
            maxAttempts: 2,
            retryDelay: noDelay
        )

        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        let updates = await collectUntilTerminal(coordinator, entryID: entry.id)

        #expect(updates.last == .failed(.throttled))
        let recorded = await analyzer.recordedTexts()
        #expect(recorded.count == 2)
    }

    @Test func refusedErrorIsNotRetriedStoresNoInsightAndLeavesTextIntact() async throws {
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Original, unanalyzed text")
        let analyzer = FakeEntryAnalyzer(script: [.failure(.refused)])
        let coordinator = EnrichmentCoordinator(
            store: store,
            analyzer: analyzer,
            maxAttempts: 3,
            retryDelay: noDelay
        )

        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        let updates = await collectUntilTerminal(coordinator, entryID: entry.id)

        #expect(updates.last == .failed(.refused))
        let recorded = await analyzer.recordedTexts()
        #expect(recorded.count == 1)

        let snapshot = try await store.snapshot(id: entry.id)
        #expect(snapshot?.text == "Original, unanalyzed text")
        #expect(snapshot?.mood == nil)
        #expect(snapshot?.summary == nil)
    }

    @Test func observerAttachedAfterEnqueueReceivesReplayedState() async throws {
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Replay me")
        let analyzer = FakeEntryAnalyzer.succeeding()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        _ = await collectUntilTerminal(coordinator, entryID: entry.id)

        // A fresh observer attaching well after the fact must immediately see the last known
        // state rather than silently missing everything that already happened.
        var replayed: EnrichmentCoordinator.EnrichmentUpdate?
        for await update in await coordinator.updates(for: entry.id) {
            replayed = update
            break
        }
        guard case .finished(let draft) = replayed else {
            Issue.record("Expected .finished replay, got \(String(describing: replayed))")
            return
        }
        #expect(draft.mood == .neutral)
    }

    @Test func updatesYieldsAnalyzingForEachPartialInOrder() async throws {
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Streaming entry")
        let partials = [
            AnalysisPartial(summary: "First partial"),
            AnalysisPartial(summary: "Second partial"),
            AnalysisPartial(summary: "Third partial")
        ]
        let result = AnalysisResult(
            mood: .good,
            moodConfidence: 0.5,
            summary: "Final summary",
            reflectionQuestion: nil,
            isPartialText: false,
            modelIdentifier: "test"
        )
        let analyzer = FakeEntryAnalyzer(script: [
            .events(partials.map(AnalysisEvent.partial) + [.finished(result)])
        ])
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        // Subscribe *before* enqueueing: `updates(for:)` only replays the single most recent
        // update to a late subscriber, so a subscription made after `enqueue()` could race the
        // (synchronously-resolving) fake analyzer and miss some or all of the partials.
        let stream = await coordinator.updates(for: entry.id)
        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        let updates = await collectUntilTerminal(stream: stream)

        let analyzingPartials: [AnalysisPartial] = updates.compactMap {
            if case .analyzing(let partial) = $0 { return partial }
            return nil
        }
        #expect(analyzingPartials == partials)
    }

}

/// A test-only analyzer whose first `analyze` call blocks until explicitly released via
/// `openGate()`, so tests can deterministically enqueue a second item for the same entry
/// while the first is still genuinely in flight — a race `FakeEntryAnalyzer` (which resolves
/// synchronously) cannot exercise.
private actor GatedAnalyzer: EntryAnalyzing {
    private(set) var texts: [String] = []
    private var gateOpen = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func prewarm() async {}

    func analyze(_ text: String) async -> AsyncThrowingStream<AnalysisEvent, any Error> {
        texts.append(text)
        notifyStarted()
        if texts.count == 1 {
            await waitForGate()
        }
        let result = AnalysisResult(
            mood: .neutral,
            moodConfidence: 0.5,
            summary: "Summary for \(text)",
            reflectionQuestion: nil,
            isPartialText: false,
            modelIdentifier: "gated-test-analyzer"
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.finished(result))
            continuation.finish()
        }
    }

    func recordedTexts() -> [String] {
        texts
    }

    func waitUntilStarted(count: Int) async {
        if texts.count >= count { return }
        await withCheckedContinuation { continuation in
            if texts.count >= count {
                continuation.resume()
            } else {
                startWaiters.append((count, continuation))
            }
        }
    }

    func openGate() {
        guard !gateOpen else { return }
        gateOpen = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForGate() async {
        if gateOpen { return }
        await withCheckedContinuation { continuation in
            if gateOpen {
                continuation.resume()
            } else {
                gateWaiters.append(continuation)
            }
        }
    }

    private func notifyStarted() {
        let ready = startWaiters.filter { texts.count >= $0.count }
        startWaiters.removeAll { texts.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
