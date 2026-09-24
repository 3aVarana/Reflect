import Testing
import Foundation
import ReflectDomain
import ReflectIntelligence
@testable import ReflectFeatures

struct InsightPanelModelTests {
    /// Polls `condition` with cooperative yields rather than a fixed sleep, so the test settles
    /// as soon as the actor pipeline actually reaches the expected state instead of racing a
    /// hard-coded delay.
    private func waitFor(maxIterations: Int = 10_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxIterations {
            await Task.yield()
            iterations += 1
        }
    }

    @Test func initialStateIsUnavailableWhenAvailabilityIsNotAvailable() {
        let model = InsightPanelModel(
            entryID: UUID(),
            coordinator: nil,
            availability: .appleIntelligenceNotEnabled
        )
        #expect(model.state == .unavailable(.appleIntelligenceNotEnabled))
    }

    @Test func initialStateIsIdleWhenAvailabilityIsAvailable() {
        let model = InsightPanelModel(entryID: UUID(), coordinator: nil, availability: .available)
        #expect(model.state == .idle)
    }

    /// Stored, not computed: `InsightDraft.generatedAt` defaults to `.now`, so a computed
    /// property would hand every access a draft that is `!=` the one the model was seeded with.
    private let storedInsight = InsightDraft(
        summary: "Stored from last session",
        reflectionQuestion: "Still true today?",
        mood: .good,
        moodConfidence: 0.7,
        modelIdentifier: "test",
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    @Test func persistedInsightStartsReadyWithThatDraftWhenAvailable() {
        // Regression for the relaunch bug: an entry analysed in a previous session must render
        // its stored insight immediately. A fresh process has an empty coordinator replay
        // cache, so nothing else will ever move the model out of `.idle`.
        let model = InsightPanelModel(
            entryID: UUID(),
            coordinator: nil,
            availability: .available,
            persistedInsight: storedInsight
        )
        #expect(model.state == .ready)
        #expect(model.lastDraft == storedInsight)
        #expect(model.canReanalyze)
    }

    @Test func persistedInsightIsIgnoredWhenUnavailable() {
        // The unavailable message wins over stale content, and `.ready` would offer a
        // "Re-analyze" button that cannot work.
        let model = InsightPanelModel(
            entryID: UUID(),
            coordinator: nil,
            availability: .modelNotReady,
            persistedInsight: storedInsight
        )
        #expect(model.state == .unavailable(.modelNotReady))
        #expect(model.lastDraft == nil)
        #expect(!model.canReanalyze)
    }

    @Test func persistedInsightSurvivesObservingACoordinatorWithNoHistoryForTheEntry() async throws {
        // The relaunch shape end to end: a live coordinator that has never seen this entry
        // (nothing to replay) must not disturb the seeded `.ready` state.
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "An entry")
        let coordinator = EnrichmentCoordinator(
            store: store,
            analyzer: FakeEntryAnalyzer.succeeding(),
            retryDelay: { _ in }
        )
        let model = InsightPanelModel(
            entryID: entry.id,
            coordinator: coordinator,
            availability: .available,
            persistedInsight: storedInsight
        )
        let observeTask = Task { await model.observe() }
        for _ in 0..<50 { await Task.yield() }

        #expect(model.state == .ready)
        #expect(model.lastDraft == storedInsight)

        observeTask.cancel()
    }

    @Test func aLaterFinishedUpdateReplacesThePersistedInsight() async throws {
        // Editing an analysed entry: the seeded draft is a starting point, not a pin. The
        // coordinator's next `.finished` for this entry must win.
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "An entry")
        let analyzer = FakeEntryAnalyzer(script: [
            .events([.finished(AnalysisResult(
                mood: .low,
                moodConfidence: 0.5,
                summary: "Fresh from this session",
                reflectionQuestion: nil,
                isPartialText: false,
                modelIdentifier: "test"
            ))])
        ])
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: { _ in })
        let model = InsightPanelModel(
            entryID: entry.id,
            coordinator: coordinator,
            availability: .available,
            persistedInsight: storedInsight
        )
        let observeTask = Task { await model.observe() }
        await coordinator.enqueue(entryID: entry.id, text: "An entry, edited")

        await waitFor { model.lastDraft?.summary == "Fresh from this session" }
        #expect(model.state == .ready)
        #expect(model.lastDraft?.summary == "Fresh from this session")
        #expect(model.lastDraft?.mood == .low)

        observeTask.cancel()
    }

    @Test func initialStateNeverTransitionsToQueuedOnItsOwn() {
        // Regression: constructing the model must never itself kick off observation. Only an
        // explicit `observe()` call (driven by `.task(id:)` in the real view) does that.
        let model = InsightPanelModel(
            entryID: UUID(),
            coordinator: nil,
            availability: .appleIntelligenceNotEnabled
        )
        #expect(model.state == .unavailable(.appleIntelligenceNotEnabled))
    }

    @Test func nilCoordinatorLeavesModelInANonCrashingIdleState() async {
        let model = InsightPanelModel(entryID: UUID(), coordinator: nil, availability: .available)
        #expect(model.state == .idle)

        // `observe()` on a nil coordinator must return immediately rather than hang or crash.
        await model.observe()
        #expect(model.state == .idle)

        model.reanalyze(text: "irrelevant")
        #expect(model.state == .idle)
    }

    @Test func observeMapsEachCoordinatorUpdateIntoTheCorrespondingState() async throws {
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "An entry")
        let analyzer = StepAnalyzer()
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: { _ in })
        let model = InsightPanelModel(entryID: entry.id, coordinator: coordinator, availability: .available)
        #expect(model.state == .idle)

        let observeTask = Task { await model.observe() }
        await coordinator.enqueue(entryID: entry.id, text: entry.text)

        await waitFor { model.state == .queued }
        #expect(model.state == .queued)

        await analyzer.waitUntilReady()
        let partial = AnalysisPartial(summary: "In progress")
        await analyzer.send(.partial(partial))
        await waitFor {
            if case .streaming = model.state { return true }
            return false
        }
        #expect(model.state == .streaming(partial))

        let result = AnalysisResult(
            mood: .good,
            moodConfidence: 0.6,
            summary: "Done",
            reflectionQuestion: "What now?",
            isPartialText: false,
            modelIdentifier: "test"
        )
        await analyzer.send(.finished(result))
        await analyzer.finish()
        await waitFor { model.state == .ready }
        #expect(model.state == .ready)
        // Critical fix: the editor always passes `insight: nil` (there is no persisted row
        // yet), so `InsightPanel` must be able to render mood/summary/question from the model
        // itself once `.ready` — otherwise everything the user just watched stream in vanishes
        // the instant analysis completes.
        #expect(model.lastDraft?.summary == "Done")
        #expect(model.lastDraft?.reflectionQuestion == "What now?")
        #expect(model.lastDraft?.mood == .good)

        observeTask.cancel()
    }

    @Test func observeMapsAFailedEventIntoFailedState() async throws {
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entry = try await store.insert(text: "An entry")
        let analyzer = StepAnalyzer()
        let coordinator = EnrichmentCoordinator(
            store: store,
            analyzer: analyzer,
            maxAttempts: 1,
            retryDelay: { _ in }
        )
        let model = InsightPanelModel(entryID: entry.id, coordinator: coordinator, availability: .available)

        let observeTask = Task { await model.observe() }
        await coordinator.enqueue(entryID: entry.id, text: entry.text)
        await analyzer.waitUntilReady()
        await analyzer.fail(.refused)

        await waitFor { model.state == .failed(.refused) }
        #expect(model.state == .failed(.refused))

        observeTask.cancel()
    }

    @Test func twoModelsForDifferentEntriesNeverCrossContaminateEachOthersState() async throws {
        // Critical fix regression: `InsightPanel` pairs a fresh `InsightPanelModel` (via
        // `.id(entryID)`) with every distinct entry, rather than reusing one `@State` instance
        // across entries. This test pins the guarantee that makes that fix correct: a model
        // constructed for one `entryID` only ever reflects *that* entry's updates, even when
        // both share the same coordinator and both are in flight at once — so a switched
        // selection (or "Re-analyze") can never write or render one entry's content under
        // another's id.
        let container = try ReflectModelContainer.makeInMemory()
        let store = JournalStore(modelContainer: container)
        let entryA = try await store.insert(text: "Entry A")
        let entryB = try await store.insert(text: "Entry B")
        let analyzer = FakeEntryAnalyzer(script: [
            .events([.finished(AnalysisResult(
                mood: .great,
                moodConfidence: 0.9,
                summary: "About A",
                reflectionQuestion: nil,
                isPartialText: false,
                modelIdentifier: "test"
            ))]),
            .events([.finished(AnalysisResult(
                mood: .low,
                moodConfidence: 0.4,
                summary: "About B",
                reflectionQuestion: nil,
                isPartialText: false,
                modelIdentifier: "test"
            ))])
        ])
        let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer, retryDelay: { _ in })

        let modelA = InsightPanelModel(entryID: entryA.id, coordinator: coordinator, availability: .available)
        let modelB = InsightPanelModel(entryID: entryB.id, coordinator: coordinator, availability: .available)

        let taskA = Task { await modelA.observe() }
        let taskB = Task { await modelB.observe() }

        await coordinator.enqueue(entryID: entryA.id, text: "Entry A")
        await coordinator.enqueue(entryID: entryB.id, text: "Entry B")

        await waitFor { modelA.state == .ready && modelB.state == .ready }

        #expect(modelA.state == .ready)
        #expect(modelB.state == .ready)
        #expect(modelA.lastDraft?.summary == "About A")
        #expect(modelA.lastDraft?.mood == .great)
        #expect(modelB.lastDraft?.summary == "About B")
        #expect(modelB.lastDraft?.mood == .low)

        taskA.cancel()
        taskB.cancel()
    }
}

/// A test-only analyzer that hands back a stream whose events are entirely controlled by the
/// test, one call at a time, so each `EnrichmentCoordinator.EnrichmentUpdate` case can be
/// observed in isolation without racing a real (synchronous) fake.
private actor StepAnalyzer: EntryAnalyzing {
    private var continuation: AsyncThrowingStream<AnalysisEvent, any Error>.Continuation?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    func prewarm() async {}

    func analyze(_ text: String) async -> AsyncThrowingStream<AnalysisEvent, any Error> {
        AsyncThrowingStream<AnalysisEvent, any Error> { continuation in
            self.continuation = continuation
            let waiters = self.readyWaiters
            self.readyWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilReady() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            if self.continuation != nil {
                continuation.resume()
            } else {
                readyWaiters.append(continuation)
            }
        }
    }

    func send(_ event: AnalysisEvent) {
        continuation?.yield(event)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func fail(_ error: IntelligenceError) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}
