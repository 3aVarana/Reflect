import Foundation
import ReflectDomain

/// One update from an in-progress or completed analysis.
nonisolated public enum AnalysisEvent: Sendable, Equatable {
    case partial(AnalysisPartial)
    case finished(AnalysisResult)
}

/// The seam `ReflectFeatures` and `EnrichmentCoordinator` depend on, instead of the concrete
/// `IntelligenceEngine`. `analyze` is `async` (not `async throws`) so an `actor` can conform
/// directly, and failures are delivered by finishing the returned stream with an
/// `IntelligenceError` — `analyze` itself never throws, so a failed analysis can never take
/// down a caller that is mid-save.
nonisolated public protocol EntryAnalyzing: Sendable {
    func analyze(_ text: String) async -> AsyncThrowingStream<AnalysisEvent, any Error>
    func prewarm() async
}

/// Scripted `EntryAnalyzing` for previews, view-model tests and coordinator tests.
nonisolated public final class FakeEntryAnalyzer: EntryAnalyzing, Sendable {
    public enum Script: Sendable {
        case events([AnalysisEvent])
        case failure(IntelligenceError)
    }

    private let script: [Script]
    private let recorder = Recorder()

    public init(script: [Script]) {
        self.script = script
    }

    /// Consumes one script entry per call, keyed by call index; once the script is exhausted
    /// the last entry repeats for every subsequent call.
    public func analyze(_ text: String) async -> AsyncThrowingStream<AnalysisEvent, any Error> {
        let index = await recorder.record(text)
        guard !script.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        let item = script[min(index, script.count - 1)]
        return AsyncThrowingStream { continuation in
            switch item {
            case .events(let events):
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    public func prewarm() async {}

    public func recordedTexts() async -> [String] {
        await recorder.texts
    }

    /// A scripted analyzer that always succeeds immediately with the given mood/summary, for
    /// previews.
    public static func succeeding(
        mood: Mood = .neutral,
        summary: String = "You wrote about your day."
    ) -> FakeEntryAnalyzer {
        let result = AnalysisResult(
            mood: mood,
            moodConfidence: 0.8,
            summary: summary,
            reflectionQuestion: "What made today feel this way?",
            isPartialText: false,
            modelIdentifier: "fake-entry-analyzer"
        )
        return FakeEntryAnalyzer(script: [.events([.finished(result)])])
    }

    /// Records `analyze` call count and received texts. A plain `actor`, not `@unchecked
    /// Sendable`, so the recording stays data-race safe without opting out of the compiler's
    /// checking.
    private actor Recorder {
        private(set) var texts: [String] = []

        func record(_ text: String) -> Int {
            texts.append(text)
            return texts.count - 1
        }
    }
}
