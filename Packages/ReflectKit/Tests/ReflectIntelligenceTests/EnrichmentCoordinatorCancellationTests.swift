import Testing
import Foundation
import SwiftData
import ReflectDomain
@testable import ReflectIntelligence

/// Warning fix: `cancel(entryID:)` used to cancel the in-flight `Task` (or drop a queued item)
/// without ever broadcasting a terminal update, leaving every observer (and the replay cache)
/// stuck on `.queued`/`.analyzing` — a spinner that never ends. Split into its own file,
/// alongside `EnrichmentCoordinatorTests`, purely to keep both files under a reasonable length.
struct EnrichmentCoordinatorCancellationTests {
    private func makeStore() throws -> (container: ModelContainer, store: JournalStore) {
        let container = try ReflectModelContainer.makeInMemory()
        return (container, JournalStore(modelContainer: container))
    }

    /// Injected so tests never actually sleep during a retry backoff.
    private func noDelay(_ attempt: Int) async {}

    /// Collects every update from an already-obtained stream up to and including the first
    /// terminal one (`.finished`/`.failed`).
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

    @Test func cancellingAnInFlightRunBroadcastsFailedCancelled() async throws {
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Cancel me")
        let analyzer = StreamAnalyzer()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        let stream = await coordinator.updates(for: entry.id)
        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        // Wait until the analyzer has genuinely started (its stream exists and `process` is
        // suspended awaiting the first event) before cancelling, so this exercises the
        // in-flight cancellation path rather than a queued-but-not-yet-started one.
        await analyzer.waitUntilReady()

        await coordinator.cancel(entryID: entry.id)

        let updates = await collectUntilTerminal(stream: stream)
        #expect(updates.last == .failed(.cancelled))
    }

    @Test func cancellingAQueuedButNotYetStartedItemBroadcastsFailedCancelled() async throws {
        let (_, store) = try makeStore()
        let first = try await store.insert(text: "First, in flight")
        let second = try await store.insert(text: "Second, only queued")
        let analyzer = StreamAnalyzer()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        let secondStream = await coordinator.updates(for: second.id)
        await coordinator.enqueue(entryID: first.id, text: first.text)
        await analyzer.waitUntilReady()
        // `second` is now sitting in the queue behind the still-in-flight `first`.
        await coordinator.enqueue(entryID: second.id, text: second.text)

        await coordinator.cancel(entryID: second.id)

        let updates = await collectUntilTerminal(stream: secondStream)
        #expect(updates.last == .failed(.cancelled))
    }

    @Test func cancellingAfterASupersedingEnqueueStillBroadcastsFailedCancelled() async throws {
        // Warning fix: `cancel(entryID:)` landing right after `enqueue` had already superseded
        // the in-flight run used to be swallowed by the `supersededIDs` marker — `process`
        // believed a fresh `.queued`/`.analyzing` sequence was already on its way, but `cancel`
        // had just deleted that superseding item from the queue, so no terminal update was ever
        // broadcast and every observer stayed stuck on `.queued`/`.analyzing` forever. Sequence:
        // enqueue original text, wait for it to genuinely start, enqueue newer text (supersede),
        // then cancel — a terminal `.failed(.cancelled)` must still arrive.
        let (_, store) = try makeStore()
        let entry = try await store.insert(text: "Original text")
        let analyzer = StreamAnalyzer()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: noDelay)

        let stream = await coordinator.updates(for: entry.id)
        await coordinator.enqueue(entryID: entry.id, text: "Original text")
        await analyzer.waitUntilReady()

        await coordinator.enqueue(entryID: entry.id, text: "Newer text")
        await coordinator.cancel(entryID: entry.id)

        let updates = await collectUntilTerminal(stream: stream)
        #expect(updates.last == .failed(.cancelled))
    }
}

/// A test-only analyzer whose `analyze` call resolves immediately (unlike `GatedAnalyzer` in
/// `EnrichmentCoordinatorTests`, which blocks *before* returning a stream, inside a plain
/// `withCheckedContinuation` that does not observe task cancellation), but whose returned
/// stream never yields anything until the test tells it to. Used for cancellation tests:
/// cancelling the task that's suspended inside `for try await event in stream` is exactly the
/// case `AsyncThrowingStream` is documented to respond to (the iterator finishes quietly
/// rather than hanging).
///
/// Not `private`: reused from `EnrichmentCoordinatorTests` for a supersede test that needs the
/// same "never yields until told to" control over more than one `analyze` call in a row.
/// `continuations` is therefore a list, one per call, rather than a single overwritten value.
actor StreamAnalyzer: EntryAnalyzing {
    private var continuations: [AsyncThrowingStream<AnalysisEvent, any Error>.Continuation] = []
    private var readyWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func prewarm() async {}

    func analyze(_ text: String) async -> AsyncThrowingStream<AnalysisEvent, any Error> {
        AsyncThrowingStream<AnalysisEvent, any Error> { continuation in
            self.continuations.append(continuation)
            let ready = self.readyWaiters.filter { self.continuations.count >= $0.count }
            self.readyWaiters.removeAll { self.continuations.count >= $0.count }
            for waiter in ready {
                waiter.continuation.resume()
            }
        }
    }

    /// Waits until at least `count` `analyze` calls have produced a live stream continuation.
    func waitUntilReady(count: Int = 1) async {
        if continuations.count >= count { return }
        await withCheckedContinuation { continuation in
            if continuations.count >= count {
                continuation.resume()
            } else {
                readyWaiters.append((count, continuation))
            }
        }
    }

    /// Finishes the most recently started (highest-index) stream with `.finished(result)`.
    func finishLatest(with result: AnalysisResult) {
        continuations.last?.yield(.finished(result))
        continuations.last?.finish()
    }
}
