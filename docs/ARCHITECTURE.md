# Reflect — Architecture

Status: v1 baseline, decided 2026-09-22. Update this file when a decision changes.

## 1. Product in one paragraph

Reflect is a private journal. You write (or speak) a free-form entry; the phone's on-device
model turns it into structured insight: a mood, the themes you keep returning to, the things
you said you'd do, and a question worth sitting with. Over a week those insights roll up into
a digest and trends. Nothing leaves the device: no backend, no accounts, no API keys, no
analytics. The app is fully usable without Apple Intelligence; insight is a layer on top of a
good journal, never a gate in front of it.

## 2. Decisions (and why)

| Decision | Choice | Why |
|---|---|---|
| Platforms | iPhone + iPad, iOS 26.0 minimum, built with the iOS 27 SDK | Foundation Models baseline is iOS 26. iPad gives an adaptive-layout showcase at low cost. macOS/visionOS were dropped to keep scope honest. |
| Structure | Thin app target + local Swift package `ReflectKit` with four modules | Enforced boundaries, fast unit tests without the app host, and the dependency graph itself documents the design. |
| Language mode | Swift 6, default `MainActor` isolation | Data-race safety is checked by the compiler. Default isolation keeps UI code boilerplate-free; background work is explicit. |
| State | SwiftUI `@Observable` view models, `@Query` for lists, `@ModelActor` for background writes | Pure Apple stack; no third-party dependencies at all. |
| AI runtime | `SystemLanguageModel` on-device only | The privacy promise. `PrivateCloudComputeLanguageModel` (iOS 27) is deliberately not used. |
| AI output | `@Generable` structs with `@Guide` constraints, streamed | Guided generation is the framework's headline feature and removes all output parsing. |
| Persistence of AI output | Stored as derived, versioned records next to the entry | Raw text stays the truth; prompts can evolve and entries can be re-analyzed. |
| Tests | Swift Testing in the package; live-model tests gated on availability | Deterministic fakes for logic, opt-in real-model tests for prompt quality. |

## 3. Module map

```
┌──────────────────────────────────────────────────────────────┐
│ Reflect (app target)   composition root, scene lifecycle     │
└───────────────┬──────────────────────────────────────────────┘
                │ imports ReflectFeatures, ReflectDomain
┌───────────────▼──────────────────────────────────────────────┐
│ ReflectFeatures   SwiftUI screens, view models, design system│
└───────┬───────────────────┬──────────────────────┬───────────┘
        │                   │                      │
┌───────▼─────────┐ ┌───────▼─────────┐            │
│ReflectIntelligence│ │ ReflectSpeech  │            │
│ Foundation Models │ │ SpeechAnalyzer │            │
└───────┬─────────┘ └────────────────┘            │
        │                                          │
┌───────▼──────────────────────────────────────────▼───────────┐
│ ReflectDomain   SwiftData models, value types, repositories  │
└──────────────────────────────────────────────────────────────┘
```

Rules:
- Arrows only point down. `ReflectDomain` imports nothing but Foundation and SwiftData.
- `FoundationModels` is imported only inside `ReflectIntelligence`; `Speech`/`AVFAudio`
  only inside `ReflectSpeech`.
- Features depend on protocols from Intelligence/Speech, never on concrete engines, so
  every screen has a preview and a test with a fake.

Planned later modules: `ReflectHealth` (HealthKit State of Mind + correlations) and a
`ReflectWidgets` extension target sharing `ReflectDomain` through an App Group.

## 4. ReflectDomain

### Models (SwiftData)

```
JournalEntry
  id: UUID (unique), createdAt, updatedAt, text, source: EntrySource (.typed | .voice)
  mood: Mood?                         denormalised from the latest insight for cheap queries
  insight: EntryInsight?              1:1, cascade delete
  themes: [Theme]                     many-to-many
  actionItems: [ActionItem]           1:many, cascade delete

EntryInsight
  summary: String, reflectionQuestion: String?
  mood: Mood, moodConfidence: Double
  analysisVersion: Int                bump when prompts/schemas change -> triggers re-analysis
  modelIdentifier: String             e.g. "system-language-model" (+ variant on iOS 27)
  generatedAt: Date

Theme
  name: String (unique, normalised lowercase), displayName, firstSeen, lastSeen
  entries: [JournalEntry]             inverse
  occurrenceCount computed via query

ActionItem
  title: String, isCompleted: Bool, completedAt: Date?, createdAt
  entry: JournalEntry                 inverse

WeeklyDigest
  weekStart: Date (unique), headline, narrative, highlights: [String]
  recurringThemes: [String], suggestedFocus: String?
  averageMoodScore: Double, entryCount: Int, generatedAt, analysisVersion
```

Value types: `Mood` (five points, numeric score), `EntrySource`, `DateRange` helpers,
`MoodTrendPoint` for charts.

### Access

- `ReflectModelContainer.make()` / `.makeInMemory()` own the schema.
- `JournalStore: @ModelActor` performs all background reads/writes (enrichment results,
  digest writes, bulk operations) and exposes plain `Sendable` snapshots
  (`EntrySnapshot`) to other modules.
- Views use `@Query` directly for lists; that is idiomatic SwiftUI and keeps the UI live.

## 5. ReflectIntelligence

### Public surface

```swift
protocol EntryAnalyzing   { func analyze(_ text: String) -> AsyncThrowingStream<EntryAnalysis.PartiallyGenerated, Error> }
protocol DigestGenerating { func digest(for week: DateRange) async throws -> WeeklyDigestDraft }
protocol ReflectionPrompting { func question(after analysis: EntryAnalysis) async throws -> String }
enum IntelligenceAvailability  // wraps SystemLanguageModel.Availability
enum IntelligenceError         // app-facing mapping of GenerationError
```

### Generable schemas (the showcase)

```swift
@Generable
struct EntryAnalysis {
  @Guide(description: "Overall mood of the writer") var mood: Mood        // Mood is @Generable too
  @Guide(.range(0...1)) var moodConfidence: Double
  @Guide(description: "One sentence, second person, no advice") var summary: String
  @Guide(.maximumCount(3)) var themes: [ThemeTag]                          // short noun phrases
  @Guide(.maximumCount(5)) var actionItems: [String]                       // only explicit intentions
  @Guide(description: "One open question that helps the writer reflect") var reflectionQuestion: String
}

@Generable
struct WeeklyDigestDraft { headline, narrative, highlights (≤3), recurringThemes (≤3), suggestedFocus }
```

### Engine

- `IntelligenceEngine` is an **actor** that owns one `LanguageModelSession` per task kind
  (`analysis`, `digest`). `LanguageModelSession` is not `Sendable` and rejects concurrent
  requests, so the actor serialises work and is the only place sessions live.
- Analysis uses `SystemLanguageModel(useCase: .contentTagging)` for mood/theme extraction
  (the tagging adapter is tuned for exactly this) and the `.general` model for summary,
  digest and reflection question.
- Streaming: `streamResponse(generating: EntryAnalysis.self)` yields
  `EntryAnalysis.PartiallyGenerated`; the editor renders fields as they appear.
- `prewarm()` is called when the app enters the foreground and when the editor opens.
- Sessions are recreated (fresh transcript) per entry; there is no multi-turn state to leak.

### Tool calling

`RecentEntriesTool` and `ThemeHistoryTool` conform to `Tool` and read through
`JournalStore`. The digest session is created with these tools so the model can ask "what
did the writer say about *work* this month?" instead of receiving a giant prompt. This is
the second headline capability of the framework and it also keeps prompts inside the
context window.

### Error policy

| `GenerationError` | Handling |
|---|---|
| `exceededContextWindowSize` | Chunk the entry (paragraph boundaries), analyze the first ~2.5k tokens, mark insight as `partial`. Digest: reduce the entry set, rely on tools. |
| `guardrailViolation`, `refusal` | Store no insight, show "Reflect couldn't analyze this entry" without judgement, allow retry. Never surface the raw error. |
| `unsupportedLanguageOrLocale` | Show message once, don't retry automatically. |
| `rateLimited`, `concurrentRequests` | Back off and requeue (the actor should make `concurrentRequests` impossible). |
| `assetsUnavailable`, `decodingFailure`, `unsupportedGuide` | Log, requeue once, then give up for this `analysisVersion`. |

### iOS 27 adoption (behind `#available(iOS 27, *)`)

- `session.usage` / `contextSize` to display token budget in a debug panel and to size chunks.
- `ContextOptions(reasoningLevel:)` for the weekly digest (quality over latency).
- `TranscriptErrorHandlingPolicy.revertTranscript` on the digest session.
- `SystemLanguageModel.Variant` recorded in `EntryInsight.modelIdentifier`.
- `LanguageModel` protocol enables injecting a fake model into the real engine in tests.
- Image attachments (photo journaling) are a post-v1 phase.

## 6. ReflectSpeech

`VoiceCapture` (actor) wraps `SpeechAnalyzer` + `SpeechTranscriber` + `AVAudioEngine`:

1. Check `AssetInventory` and install the on-device model for the current locale if needed
   (`.preparingAssets`).
2. Request microphone permission (`NSMicrophoneUsageDescription` is already set).
3. Stream `AnalyzerInput` buffers from the audio engine into the analyzer.
4. Publish an `AsyncStream<TranscriptUpdate>` with volatile (in-progress) and finalized text.
5. `finish()` calls `finalizeAndFinishThroughEndOfInput()` and returns the full transcript,
   which becomes a `JournalEntry` with `source = .voice` and enters the same enrichment path.

State machine: `VoiceCaptureState` (`idle → preparingAssets → listening → finishing → idle`,
or `failed`). Audio is never written to disk.

## 7. ReflectFeatures

Feature folders, each with a view, an `@Observable` view model where logic exists, and
previews backed by fakes:

- `Journal/` list grouped by day, search, swipe-to-delete, new entry.
- `Editor/` text editor + voice button; enrichment streams into an `InsightPanel` as the
  user finishes writing (debounced, cancellable).
- `EntryDetail/` full text with mood glyph, summary, theme chips, action items, question.
- `Insights/` weekly digest card, mood trend chart (Swift Charts), theme timeline,
  action-items inbox.
- `Settings/` intelligence status, privacy explainer, export (JSON) and delete-all.
- `DesignSystem/` `MoodGlyph`, `InsightCard`, `ThemeChip`, spacing/colour tokens.

Navigation: `TabView` on iPhone, `NavigationSplitView` on iPad, chosen by
`horizontalSizeClass`. Dependencies (engine, store, voice capture) are injected through
the SwiftUI environment from the app target.

## 8. Data flow for one entry

```
Editor saves text ──► JournalStore.insert (MainActor context)
                           │
                           ▼
        EnrichmentCoordinator.enqueue(entryID)   (actor, serial queue, dedup)
                           │
                           ▼
        IntelligenceEngine.analyze(text) ──stream──► Editor InsightPanel (partial)
                           │ final
                           ▼
        JournalStore.applyInsight(entryID, analysis, version)
                           │
                           ▼
        @Query views update (list mood glyphs, detail, themes, action items)
```

Re-analysis triggers: `analysisVersion` bump, user tap "Re-analyze", entry text edited.

## 9. Concurrency model

- Everything is `MainActor` by default. Background work is opted in via actors
  (`IntelligenceEngine`, `EnrichmentCoordinator`, `VoiceCapture`) and `@ModelActor`
  (`JournalStore`).
- Cross-actor values are `Sendable` snapshots; SwiftData model objects never cross actors.
- Long-running streams are cancelled with the owning view's task (`.task(id:)`).

## 10. Privacy posture

- No network code exists in the package. Reviewers can verify with a grep for `URLSession`.
- `PrivacyInfo.xcprivacy` declares no tracking and no collected data.
- Export is a local JSON file via the share sheet; delete-all wipes the store.
- Onboarding explains in one screen that analysis happens on the device and what happens
  when Apple Intelligence is off.

## 11. Testing strategy

| Layer | How |
|---|---|
| Domain | In-memory `ModelContainer`, repository and query tests. |
| Intelligence | `FakeEntryAnalyzer` for logic; error-mapping tests; live prompt-quality tests gated with `.enabled(if: SystemLanguageModel.default.isAvailable)` and a small golden set of entries. |
| Speech | State machine tests with a fake audio source; live tests skipped in CI. |
| Features | View-model tests with fakes; preview coverage for every screen. |
| App | Xcode UI test target added via Xcode once the flows stabilise (Phase 6). |
