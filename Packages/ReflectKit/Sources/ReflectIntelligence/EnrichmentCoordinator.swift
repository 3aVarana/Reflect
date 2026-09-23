import Foundation
import ReflectDomain

/// The serial queue between saving an entry and persisting its insight. Owns no
/// `LanguageModelSession` itself — that lives in the injected `analyzer` — but is the single
/// place that decides what gets analyzed, in what order, with what retry policy, and how the
/// result reaches `JournalStore`.
public actor EnrichmentCoordinator {
    /// One update broadcast to every observer of a given entry. `finished` carries the
    /// `InsightDraft` that was just persisted so observers (e.g. `InsightPanelModel`) can
    /// render mood/summary/question immediately without depending on a separately-fetched,
    /// possibly-stale `EntryInsight` — the streamed content must not vanish the moment
    /// analysis completes.
    nonisolated public enum EnrichmentUpdate: Sendable, Equatable {
        case queued
        case analyzing(AnalysisPartial)
        case finished(InsightDraft)
        case failed(IntelligenceError)
    }

    private let store: JournalStore
    private let analyzer: any EntryAnalyzing
    private let maxAttempts: Int
    private let retryDelay: @Sendable (Int) async -> Void
    /// Injected so the `.unknown → .modelUnavailable` remap in `process` (below) is reachable
    /// from a test without depending on the build host's real Apple Intelligence state — the
    /// default reads live `IntelligenceAvailability.current` in production.
    private let availability: @Sendable () -> IntelligenceAvailability

    private var queue: [(id: UUID, text: String)] = []
    /// The item currently being analyzed, if any. Tracked separately from `queue` (which the
    /// item is removed from before analysis starts) so dedup can compare against it.
    private var current: (id: UUID, text: String)?
    /// A fresh `Task` per item, not the outer drain loop's task: cancelling one entry's
    /// analysis must not cancel the drain loop itself, or every subsequent queued item would
    /// also observe a cancelled `Task` and fail.
    private var currentTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var attemptCounts: [UUID: Int] = [:]
    /// Ids whose in-flight run was cancelled because `enqueue` superseded it with newer text
    /// (as opposed to an explicit `cancel(entryID:)`). `process` consults this to decide
    /// whether a quiet cancellation should broadcast a terminal `.failed(.cancelled)` (external
    /// cancel) or stay silent because a fresh `.queued`/`.analyzing` sequence for the same id is
    /// already on its way (supersede).
    private var supersededIDs: Set<UUID> = []

    private var observers: [UUID: [UUID: AsyncStream<EnrichmentUpdate>.Continuation]] = [:]
    private var lastUpdate: [UUID: EnrichmentUpdate] = [:]

    public init(
        store: JournalStore,
        analyzer: any EntryAnalyzing,
        maxAttempts: Int = 2,
        retryDelay: @escaping @Sendable (Int) async -> Void = { attempt in
            try? await Task.sleep(for: .milliseconds(250 * attempt))
        },
        availability: @escaping @Sendable () -> IntelligenceAvailability = { .current }
    ) {
        self.store = store
        self.analyzer = analyzer
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
        self.availability = availability
    }

    /// Enqueues an entry for analysis. Dedup: skipped entirely (no-op, no broadcast) if the
    /// in-flight item already has this exact id and text; otherwise replaces any
    /// already-queued item with the same `entryID` (the latest text wins) or appends a new
    /// one, then emits `.queued` and starts the drain loop if it is not already running.
    public func enqueue(entryID: UUID, text: String) {
        if current?.id == entryID, current?.text == text {
            return
        }
        if let index = queue.firstIndex(where: { $0.id == entryID }) {
            queue[index] = (id: entryID, text: text)
        } else {
            queue.append((id: entryID, text: text))
        }
        // A newer text for the entry currently being analyzed supersedes that run: its result
        // would be stale the instant it lands, so cancel it now rather than paying for a full
        // generation to complete before the newer text is even picked up. `process` treats
        // this cancellation as quiet (no `.failed` broadcast) because the `.queued` below is
        // already telling observers a fresh run is on its way.
        if current?.id == entryID, current?.text != text {
            supersededIDs.insert(entryID)
            currentTask?.cancel()
        }
        broadcast(.queued, to: entryID)
        startDrainLoopIfNeeded()
    }

    /// Enqueues up to `limit` stale entries. Called once at launch.
    public func enqueueStale(limit: Int = 5) async {
        let ids = (try? await store.idsNeedingAnalysis(limit: limit)) ?? []
        for id in ids {
            guard let snapshot = try? await store.snapshot(id: id) else { continue }
            enqueue(entryID: id, text: snapshot.text)
        }
    }

    /// Drops a queued item; cancels the in-flight generation if it is the one running.
    /// Broadcasts a terminal `.failed(.cancelled)` so no observer (or the replay cache) is
    /// ever left stuck on `.queued`/`.analyzing` for an entry that is no longer being worked
    /// on. If the item was in flight, `process` itself detects the cancellation (its analyzer
    /// loop ends without a `.finished` event) and broadcasts there instead, to avoid a race
    /// between this method returning and that broadcast landing.
    ///
    /// Also clears `supersededIDs[entryID]` unconditionally. Without this, a `cancel` landing
    /// right after `enqueue` had superseded the same id (newer text in flight) would remove the
    /// superseding item from `queue` above while leaving the marker in place; `process` would
    /// then read that marker as "a fresh `.queued`/`.analyzing` sequence is already on its way"
    /// for a run that `cancel` had just deleted, and stay quiet forever — the exact
    /// never-ending-spinner bug this file's other terminal-broadcast fixes close, reopened on
    /// this third path. Clearing it here makes `process`'s cancellation-detection broadcast the
    /// terminal update instead, regardless of which of `current`/`queue` the entry was in.
    public func cancel(entryID: UUID) {
        let wasQueued = queue.contains { $0.id == entryID }
        queue.removeAll { $0.id == entryID }
        supersededIDs.remove(entryID)
        if current?.id == entryID {
            currentTask?.cancel()
        } else if wasQueued {
            attemptCounts.removeValue(forKey: entryID)
            broadcast(.failed(.cancelled), to: entryID)
        }
    }

    public func reanalyze(entryID: UUID, text: String) async {
        _ = try? await store.clearInsight(entryID: entryID)
        enqueue(entryID: entryID, text: text)
    }

    /// Registers an observer for `entryID`, immediately replaying the last known update so a
    /// view that attaches after `enqueue` still renders the right state. `onTermination` hops
    /// back onto the actor to deregister the continuation.
    public func updates(for entryID: UUID) -> AsyncStream<EnrichmentUpdate> {
        let token = UUID()
        return AsyncStream { continuation in
            observers[entryID, default: [:]][token] = continuation
            if let last = lastUpdate[entryID] {
                continuation.yield(last)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeObserver(token, for: entryID) }
            }
        }
    }

    public func prewarm() async {
        await analyzer.prewarm()
    }

    private func removeObserver(_ token: UUID, for entryID: UUID) {
        observers[entryID]?.removeValue(forKey: token)
        if observers[entryID]?.isEmpty == true {
            observers.removeValue(forKey: entryID)
        }
    }

    private func broadcast(_ update: EnrichmentUpdate, to entryID: UUID) {
        lastUpdate[entryID] = update
        guard let continuations = observers[entryID] else { return }
        for continuation in continuations.values {
            continuation.yield(update)
        }
    }

    private func startDrainLoopIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task {
            await self.drain()
            self.drainTask = nil
            // More work may have arrived while this drain task was tearing down.
            if !self.queue.isEmpty {
                self.startDrainLoopIfNeeded()
            }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            current = item
            let task = Task {
                await self.process(id: item.id, text: item.text)
            }
            currentTask = task
            await task.value
            current = nil
            currentTask = nil
        }
    }

    /// Runs one entry through the analyzer, retrying on a retryable error up to `maxAttempts`
    /// (attempt counters keyed by entry id). A failure never removes or alters the entry's
    /// text and never propagates out of the coordinator — every path here ends in a broadcast,
    /// not a thrown error.
    private func process(id: UUID, text: String) async {
        let attempt = (attemptCounts[id] ?? 0) + 1
        attemptCounts[id] = attempt

        do {
            let stream = await analyzer.analyze(text)
            var didFinish = false
            for try await event in stream {
                switch event {
                case .partial(let partial):
                    broadcast(.analyzing(partial), to: id)
                case .finished(let result):
                    attemptCounts.removeValue(forKey: id)
                    // A run that reaches `.finished` despite an earlier `enqueue`-driven
                    // supersede attempt (e.g. the cancellation raced a `LanguageModelSession`
                    // call that doesn't observe cooperative cancellation) completed on its own
                    // terms — clear the stale marker so it can never suppress a *later*,
                    // unrelated cancellation's broadcast.
                    supersededIDs.remove(id)
                    didFinish = true
                    await persist(result: result, id: id)
                }
            }
            if !didFinish {
                // The analyzer's stream ended with neither a `.finished` event nor a thrown
                // error. The only way that happens is the consuming task (`currentTask`) being
                // cancelled: `AsyncThrowingStream`'s iterator finishes quietly rather than
                // throwing when the task consuming it is cancelled. Distinguish an explicit
                // `cancel(entryID:)` (broadcast a terminal failure) from an `enqueue`-driven
                // supersede (stay quiet — a fresh `.queued`/`.analyzing` sequence is already on
                // its way for this id).
                attemptCounts.removeValue(forKey: id)
                if supersededIDs.remove(id) == nil {
                    broadcast(.failed(.cancelled), to: id)
                }
            }
        } catch {
            // Same reasoning as the `.finished` case above: a genuine thrown error means this
            // run did not end via a quiet supersede-cancellation, so any stale marker left over
            // from a cancellation that didn't stick must not suppress a later, unrelated one.
            supersededIDs.remove(id)
            var mapped = IntelligenceError(error)
            var forceNoRetry = false
            // An `.unknown` error is, by construction, not a documented `GenerationError` —
            // consult real availability before burning a second generation attempt on it: if
            // the model genuinely isn't available right now, no retry will ever succeed.
            if mapped == .unknown, availability() != .available {
                mapped = .modelUnavailable
                forceNoRetry = true
            }
            if !forceNoRetry, mapped.isRetryable, attempt < maxAttempts {
                await retryDelay(attempt)
                await process(id: id, text: text)
                return
            }
            attemptCounts.removeValue(forKey: id)
            if mapped.shouldStoreNoInsight {
                _ = try? await store.clearInsight(entryID: id)
            }
            broadcast(.failed(mapped), to: id)
        }
    }

    /// Persists a finished analysis. Wrapped in its own `do`/`catch`, separate from the
    /// analyzer's error handling above: a SwiftData write failure is never a generation
    /// problem, so it must never loop back through `process`'s retry logic and pay for a
    /// second multi-second model run to fix a problem that was never in the model.
    private func persist(result: AnalysisResult, id: UUID) async {
        let draft = result.draft()
        do {
            let snapshot = try await store.applyInsight(entryID: id, draft: draft)
            // `snapshot` is `nil` when the entry was deleted while analysis was in flight;
            // there is nothing left to report as finished, so move on quietly.
            if snapshot != nil {
                broadcast(.finished(draft), to: id)
            }
        } catch {
            broadcast(.failed(.unknown), to: id)
        }
    }
}
