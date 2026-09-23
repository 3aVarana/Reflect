import SwiftUI
import SwiftData
import ReflectDomain
import ReflectIntelligence

/// The real insight panel — replaces `InsightPlaceholderView`, "the seam Phase 2 replaces".
/// Renders mood, summary and reflection question, preferring live streaming values over the
/// stored `insight` so the editor visibly fills in as generation streams.
struct InsightPanel: View {
    @Environment(\.enrichmentCoordinator) private var coordinator
    @State private var model: InsightPanelModel

    private let entryID: UUID
    private let insight: EntryInsight?
    private let text: String

    /// The model is built here, eagerly, exactly like `EntryEditorViewModel` in
    /// `EntryEditorView.init` — never lazily in `.onAppear`. Unlike that case, `@Environment`
    /// values are not available inside `init`, so the model starts with `coordinator: nil` and
    /// `.task(id:)` attaches the real one once the view is actually in the hierarchy. Because
    /// `model` itself is never `Optional`, `body` never needs an `if let model { … }` branch,
    /// so the SwiftUI "`.onAppear` never fires on an empty conditional child" trap documented
    /// on `EntryEditorView.init` does not apply here regardless.
    ///
    /// Passes `IntelligenceAvailability.cachedAtLaunch` explicitly rather than relying on
    /// `InsightPanelModel.init`'s own `= .current` default: in the editor, `text:` above changes
    /// on every keystroke, so SwiftUI re-invokes this `init` (and therefore evaluates every
    /// argument to `State(initialValue:)`, even though `@State` itself only keeps the *first*
    /// resulting instance) on every keystroke. A live `.current` there would mean a
    /// FoundationModels availability call per keystroke; the cached value reads it once.
    init(entryID: UUID, insight: EntryInsight?, text: String) {
        self.entryID = entryID
        self.insight = insight
        self.text = text
        _model = State(initialValue: InsightPanelModel(
            entryID: entryID,
            coordinator: nil,
            availability: .cachedAtLaunch
        ))
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label {
                    Text("Insights", bundle: .module)
                        .font(.headline)
                } icon: {
                    Image(systemName: "sparkles")
                }
                content
                if (model.lastDraft?.isPartial ?? insight?.isPartial) == true {
                    Text(
                        "Partly analysed — this entry was long, so only the first part was used.",
                        bundle: .module
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if model.canReanalyze {
                    Button {
                        model.reanalyze(text: text)
                    } label: {
                        Text("Re-analyze", bundle: .module)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: entryID) {
            model.attach(coordinator: coordinator)
            await model.observe()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .unavailable(let availability):
            Text(availability.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .idle:
            Text("Insights will appear here once this entry is saved.", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .queued:
            HStack(spacing: Spacing.s) {
                ProgressView()
                Text("Waiting to analyze…", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .streaming(let partial):
            streamingContent(partial)
        case .ready:
            readyContent
        case .failed(let error):
            errorText(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func streamingContent(_ partial: AnalysisPartial) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                ProgressView()
                MoodGlyph(mood: partial.mood ?? insight?.mood)
            }
            if let summary = partial.summary ?? insight?.summary {
                Text(summary)
                    .font(.body)
            }
            if let question = partial.reflectionQuestion ?? insight?.reflectionQuestion {
                Text(question)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Prefers the model's own `lastDraft` (the payload of the most recent `.finished` update)
    /// over the `insight` passed in at construction: in the editor, `insight` is always `nil`
    /// (there is no persisted row to read from yet), so without this, everything the user just
    /// watched stream in would vanish the instant analysis completes.
    @ViewBuilder
    private var readyContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                MoodGlyph(mood: model.lastDraft?.mood ?? insight?.mood)
                if let summary = model.lastDraft?.summary ?? insight?.summary {
                    Text(summary)
                        .font(.body)
                }
            }
            if let question = model.lastDraft?.reflectionQuestion ?? insight?.reflectionQuestion {
                Text(question)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Every `IntelligenceError` case gets its localized copy here — `ReflectIntelligence` has
    /// no resources bundle. `refused` deliberately reads as calm and non-judgemental.
    @ViewBuilder
    private func errorText(_ error: IntelligenceError) -> some View {
        switch error {
        case .contextWindowExceeded:
            Text("This entry was too long to fully analyze.", bundle: .module)
        case .refused:
            Text("Reflect couldn't analyse this entry.", bundle: .module)
        case .unsupportedLanguage:
            Text("This entry's language isn't supported for insights yet.", bundle: .module)
        case .throttled:
            Text("Reflect is still working on a previous entry. Try again shortly.", bundle: .module)
        case .modelUnavailable:
            Text("The on-device model isn't ready yet.", bundle: .module)
        case .malformedOutput:
            Text("Reflect couldn't make sense of this entry's analysis.", bundle: .module)
        case .cancelled:
            Text("Analysis was cancelled.", bundle: .module)
        case .unknown:
            Text("Something went wrong while analyzing this entry.", bundle: .module)
        }
    }
}

#Preview("Ready") {
    let container = try! ReflectModelContainer.makeInMemory()
    let context = ModelContext(container)
    let entry = JournalEntry(text: "A short reflection on the day.")
    let insight = EntryInsight(
        summary: "You reflected on a quiet day at home.",
        reflectionQuestion: "What made today feel calm?",
        mood: .good,
        moodConfidence: 0.8,
        modelIdentifier: "preview"
    )
    context.insert(entry)
    context.insert(insight)
    entry.insight = insight
    entry.mood = .good
    try? context.save()

    let store = JournalStore(modelContainer: container)
    let coordinator = EnrichmentCoordinator(store: store, analyzer: FakeEntryAnalyzer.succeeding())

    return InsightPanel(entryID: entry.id, insight: insight, text: entry.text)
        .environment(\.enrichmentCoordinator, coordinator)
        .padding()
}

#Preview("Streaming") {
    let container = try! ReflectModelContainer.makeInMemory()
    let context = ModelContext(container)
    let entry = JournalEntry(text: "A longer reflection about the week.")
    context.insert(entry)
    try? context.save()

    let store = JournalStore(modelContainer: container)
    let analyzer = FakeEntryAnalyzer(script: [
        .events([
            .partial(AnalysisPartial(summary: "You wrote about the week…")),
            .finished(AnalysisResult(
                mood: .neutral,
                moodConfidence: 0.6,
                summary: "You reflected on the week's ups and downs.",
                reflectionQuestion: "What would make next week better?",
                isPartialText: false,
                modelIdentifier: "preview"
            ))
        ])
    ])
    let coordinator = EnrichmentCoordinator(store: store, analyzer: analyzer)

    return InsightPanel(entryID: entry.id, insight: nil, text: entry.text)
        .environment(\.enrichmentCoordinator, coordinator)
        .padding()
}
