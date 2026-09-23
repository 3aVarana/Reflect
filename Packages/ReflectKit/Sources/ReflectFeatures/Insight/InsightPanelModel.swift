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
    /// The `InsightDraft` from the most recent `.finished` update, retained here because the
    /// editor never has a persisted `EntryInsight` to fall back on (it always passes `insight:
    /// nil`): without this, everything the user just watched stream in would vanish the
    /// instant analysis completes and `state` becomes `.ready`.
    private(set) var lastDraft: InsightDraft?

    private let entryID: UUID
    /// `var`, not `let`: `@Environment` values are not available inside a SwiftUI `View`'s
    /// `init`, so `InsightPanel` builds this model eagerly with `coordinator: nil` and
    /// attaches the real one once `.task(id:)` runs (by which point the environment has been
    /// resolved), rather than deferring the model's construction itself to `.onAppear`.
    private var coordinator: EnrichmentCoordinator?

    init(
        entryID: UUID,
        coordinator: EnrichmentCoordinator?,
        availability: IntelligenceAvailability = .current
    ) {
        self.entryID = entryID
        self.coordinator = coordinator
        self.state = availability == .available ? .idle : .unavailable(availability)
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
