import Foundation
import ReflectDomain
import ReflectIntelligence

/// All state transitions for `InsightPanel` live here (not in the view) so they are testable
/// without a UI test target.
enum InsightPanelState: Equatable {
    case unavailable(IntelligenceAvailability)
    case idle
    case queued
    case streaming(AnalysisPartial)
    case ready
    case failed(IntelligenceError)
}

/// Drives `InsightPanel` from an `EnrichmentCoordinator`'s update stream.
///
/// One instance is scoped to exactly one `entryID` for its entire lifetime — there is no
/// `rebind`. `InsightPanel` pairs this with `.id(entryID)` at its call sites so that switching
/// entries (e.g. selecting a different row in an iPad split view) discards this instance
/// entirely and constructs a fresh one for the new id, rather than reusing one instance across
/// entries. (SwiftUI's `@State(initialValue:)` is "first instance wins": without `.id()`, a
/// view identity that survives a re-render keeps its original `@State` object even though the
/// view's `init` ran again with a different `entryID` — see the critical review finding this
/// documents.)
@Observable final class InsightPanelModel {
    private(set) var state: InsightPanelState
    /// What the panel renders in `.ready`: seeded from the entry's persisted insight (if any)
    /// at construction, then replaced by the payload of every `.finished` update. Seeding
    /// matters across launches — a fresh process has an empty coordinator replay cache, so
    /// without it an entry analysed last session would sit in `.idle` forever, showing
    /// "Insights will appear here…" over a row that is already in the store. Replacing
    /// matters within a session — a brand-new entry has no persisted row while the user
    /// watches it stream in, so without it everything would vanish the instant `state`
    /// becomes `.ready`.
    private(set) var lastDraft: InsightDraft?

    private let entryID: UUID
    /// `var`, not `let`: `@Environment` values are not available inside a SwiftUI `View`'s
    /// `init`, so `InsightPanel` builds this model eagerly with `coordinator: nil` and
    /// attaches the real one once `.task(id:)` runs (by which point the environment has been
    /// resolved), rather than deferring the model's construction itself to `.onAppear`.
    private var coordinator: EnrichmentCoordinator?

    /// - Parameter persistedInsight: the entry's stored insight, if it has one. When
    ///   availability is `.available` the model starts in `.ready` with `lastDraft` set to it,
    ///   so a relaunch shows last session's result immediately; any later coordinator update
    ///   for this entry still wins. Ignored when availability is not `.available`: the
    ///   unavailable message takes precedence over stale content, and `.ready` would offer a
    ///   "Re-analyze" button that cannot work.
    init(
        entryID: UUID,
        coordinator: EnrichmentCoordinator?,
        availability: IntelligenceAvailability,
        persistedInsight: InsightDraft? = nil
    ) {
        self.entryID = entryID
        self.coordinator = coordinator
        guard availability == .available else {
            self.state = .unavailable(availability)
            return
        }
        if let persistedInsight {
            self.lastDraft = persistedInsight
            self.state = .ready
        } else {
            self.state = .idle
        }
    }

    /// Supplies the coordinator once it becomes known. A no-op once a coordinator is already
    /// attached, so a re-invocation from `.task(id:)` (e.g. after a state restore) never
    /// clobbers an in-progress observation with a second one.
    func attach(coordinator: EnrichmentCoordinator?) {
        guard self.coordinator == nil, coordinator != nil else { return }
        self.coordinator = coordinator
    }

    /// Consumes `coordinator.updates(for: entryID)` until the calling task is cancelled,
    /// mapping each update into `state`. A `nil` coordinator (no environment value, e.g. in a
    /// preview or a Settings-only context) leaves the model in whatever non-crashing state it
    /// started in.
    func observe() async {
        guard let coordinator else { return }
        for await update in await coordinator.updates(for: entryID) {
            switch update {
            case .queued:
                state = .queued
            case .analyzing(let partial):
                state = .streaming(partial)
            case .finished(let draft):
                lastDraft = draft
                state = .ready
            case .failed(let error):
                state = .failed(error)
            }
        }
    }

    func reanalyze(text: String) {
        guard let coordinator else { return }
        Task {
            await coordinator.reanalyze(entryID: entryID, text: text)
        }
    }

    /// Whether the "Re-analyze" button should be shown. Derived from `state` alone (it is only
    /// ever `.ready`/`.failed` when `availability` was `.available` at construction), rather
    /// than re-querying `IntelligenceAvailability.current` — a FoundationModels call — on every
    /// `body` evaluation, which in the editor happens on every keystroke.
    var canReanalyze: Bool {
        switch state {
        case .ready, .failed:
            true
        default:
            false
        }
    }
}
