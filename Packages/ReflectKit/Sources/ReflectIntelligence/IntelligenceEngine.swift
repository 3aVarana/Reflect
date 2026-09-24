import Foundation
import FoundationModels

/// The only place a `LanguageModelSession` lives. `LanguageModelSession` is not `Sendable`
/// and rejects concurrent `respond`/`streamResponse` calls, so this actor is both the owner
/// of the session and the serialisation point: `analyze` chains every request onto a single
/// `pending` task, which makes `GenerationError.concurrentRequests` structurally impossible.
public actor IntelligenceEngine: EntryAnalyzing {
    private let model: SystemLanguageModel
    private var session: LanguageModelSession?
    private var pending: Task<Void, Never>?

    /// A plain English prompt, not UI copy, so it is not localized.
    private static let instructions = """
        You read one private journal entry and return a structured reflection. Always write \
        in the second person. Produce exactly one sentence for the summary and one open \
        question. Never give advice, never diagnose, never moralise. If the entry is very \
        short, still answer from what is there.
        """

    /// `.general` is what the app passes for Phase 2's single prose-producing request; the
    /// `useCase` parameter is the seam Phase 3 uses for `.contentTagging` theme/mood tagging.
    public init(useCase: SystemLanguageModel.UseCase = .general) {
        self.model = SystemLanguageModel(useCase: useCase)
    }

    /// Creates the session if needed and prewarms it. Never throws.
    public func prewarm() async {
        let activeSession = session ?? makeSession()
        session = activeSession
        activeSession.prewarm()
    }

    public func analyze(_ text: String) async -> AsyncThrowingStream<AnalysisEvent, any Error> {
        AsyncThrowingStream { continuation in
            let previous = pending
            // Chaining onto `previous` is the serialisation guarantee: exactly one
            // generation runs at a time.
            let task = Task {
                await previous?.value
                await self.generate(text: text, continuation: continuation)
            }
            pending = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: Self.instructions)
    }

    private func generate(
        text: String,
        continuation: AsyncThrowingStream<AnalysisEvent, any Error>.Continuation
    ) async {
        await runGeneration(text: text, maxCharacters: 8_000, isRetry: false, continuation: continuation)
    }

    /// Runs one generation attempt. On `exceededContextWindowSize`, retries once with a fresh
    /// session and half the character budget before giving up. `session` is set to `nil` in a
    /// `defer` so the next entry always gets a fresh transcript — there is no multi-turn state
    /// worth keeping, and it guarantees no transcript growth across entries — and is also set
    /// to `nil` explicitly before a retry, so the retry does not reuse the session that just
    /// overflowed.
    private func runGeneration(
        text: String,
        maxCharacters: Int,
        isRetry: Bool,
        continuation: AsyncThrowingStream<AnalysisEvent, any Error>.Continuation
    ) async {
        guard !Task.isCancelled else {
            continuation.finish(throwing: IntelligenceError.cancelled)
            return
        }

        let (budgetedText, wasTruncated) = AnalysisBudget.budgeted(text, maxCharacters: maxCharacters)
        let activeSession = session ?? makeSession()
        session = activeSession
        defer { session = nil }

        do {
            let stream = activeSession.streamResponse(to: budgetedText, generating: EntryAnalysis.self)
            // Deliberately does **not** also call `stream.collect()` after this loop:
            // `ResponseStream` is a single-pass `AsyncSequence` with no documented replay
            // semantics, so a second traversal after `for try await` has already exhausted it
            // is unverified behaviour. The final snapshot captured here carries the same
            // (by-then-complete) `PartiallyGenerated` content that `collect()` would otherwise
            // have produced, so the result is built from it directly instead.
            var lastContent: EntryAnalysis.PartiallyGenerated?
            for try await snapshot in stream {
                lastContent = snapshot.content
                continuation.yield(.partial(AnalysisPartial(snapshot.content)))
            }
            guard let result = Self.result(from: lastContent, wasTruncated: wasTruncated) else {
                continuation.finish(throwing: IntelligenceError.malformedOutput)
                return
            }
            continuation.yield(.finished(result))
            continuation.finish()
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            session = nil
            if !isRetry {
                await runGeneration(
                    text: text,
                    maxCharacters: maxCharacters / 2,
                    isRetry: true,
                    continuation: continuation
                )
            } else {
                continuation.finish(throwing: IntelligenceError.contextWindowExceeded)
            }
        } catch {
            continuation.finish(throwing: IntelligenceError(error))
        }
    }

    /// Builds the final `AnalysisResult` from the last streamed snapshot's content, treating a
    /// missing required field (never observed with valid generation, but possible if the
    /// stream ends early) as malformed rather than force-unwrapping.
    private static func result(
        from lastContent: EntryAnalysis.PartiallyGenerated?,
        wasTruncated: Bool
    ) -> AnalysisResult? {
        guard
            let content = lastContent,
            let moodTag = content.mood,
            let moodConfidence = content.moodConfidence,
            let summary = content.summary
        else {
            return nil
        }
        let trimmedQuestion = (content.reflectionQuestion ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AnalysisResult(
            mood: moodTag.mood,
            moodConfidence: moodConfidence,
            summary: summary,
            reflectionQuestion: trimmedQuestion.isEmpty ? nil : trimmedQuestion,
            isPartialText: wasTruncated,
            modelIdentifier: "system-language-model.general"
        )
    }
}

/// Pure, synchronous text budgeting with no model involvement. Kept `internal` (not
/// `public`) so it is exercised only through `@testable import ReflectIntelligence`.
/// 8,000 characters is roughly 2,000 tokens, which keeps the prompt plus schema plus output
/// inside the ~4k token context window.
nonisolated enum AnalysisBudget {
    static func budgeted(_ text: String, maxCharacters: Int = 8_000) -> (text: String, wasTruncated: Bool) {
        guard text.count > maxCharacters else {
            return (text, false)
        }
        let prefix = String(text.prefix(maxCharacters))
        if let breakRange = prefix.range(of: "\n\n", options: .backwards) {
            return (String(prefix[..<breakRange.lowerBound]), true)
        }
        if let whitespaceRange = prefix.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards) {
            return (String(prefix[..<whitespaceRange.lowerBound]), true)
        }
        return (prefix, true)
    }
}
