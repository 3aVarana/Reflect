# Reflect — Architecture

Status: v1 baseline, decided 2026-09-22. Updated 2026-09-22 for Phase 1 (final schema
relationships, delete rules and migration policy). Updated 2026-09-23 for Phase 2 (§4
`InsightDraft` + `JournalStore` insight methods; §5 rewritten to match the implemented
`ReflectIntelligence` surface and its four documented deviations from this baseline). Update
this file when a decision changes.

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
  insight: EntryInsight?              1:1, cascade delete, inverse declared on EntryInsight
  themes: [Theme]                     many-to-many, inverse declared on Theme (no @Relationship
                                       macro here — SwiftData requires exactly one side to
                                       declare `inverse:`)
  actionItems: [ActionItem]           1:many, cascade delete, inverse declared on ActionItem

EntryInsight
  summary: String, reflectionQuestion: String?
  mood: Mood, moodConfidence: Double
  analysisVersion: Int                bump when prompts/schemas change -> triggers re-analysis
  modelIdentifier: String             e.g. "system-language-model" (+ variant on iOS 27)
  generatedAt: Date, isPartial: Bool  true when the entry exceeded the context window and only
                                       a prefix was analyzed
  entry: JournalEntry?                inverse target of JournalEntry.insight

Theme
  name: String (unique, normalised lowercase), displayName, firstSeen, lastSeen
  entries: [JournalEntry]             many-to-many inverse of JournalEntry.themes,
                                       deleteRule: .nullify — a deleted entry drops out of the
                                       theme's `entries` array but the theme row survives
  occurrenceCount: Int                computed as `entries.count`

ActionItem
  title: String, isCompleted: Bool, completedAt: Date?, createdAt
  entry: JournalEntry?                inverse of JournalEntry.actionItems, deleteRule: .cascade
                                       from the JournalEntry side. Optional (not the
                                       non-optional shown in the original draft): SwiftData
                                       nils the inverse side of a relationship during cascade
                                       teardown, so a non-optional stored property here would
                                       trap when the owning entry is deleted.

WeeklyDigest
  weekStart: Date (unique), headline, narrative, highlights: [String]
  recurringThemes: [String], suggestedFocus: String?
  averageMoodScore: Double, entryCount: Int, generatedAt, analysisVersion
  Standalone — no relationships — so it can be regenerated independently of the entries it
  was computed from.
```

Delete rules, summarised: deleting a `JournalEntry` cascades its `EntryInsight` and
`ActionItem`s to zero rows, and nullifies (does not delete) any attached `Theme`s. `Theme`
and `WeeklyDigest` rows are never reachable by cascade from `JournalEntry`, so
`JournalStore.deleteAll()` deletes them explicitly.

Value types: `Mood` (five points, numeric score), `EntrySource`, `EntrySnapshot` (the
`Sendable` projection of `JournalEntry` that crosses actor boundaries), `InsightDraft` (the
`Sendable` projection of an analysis result that crosses from `ReflectIntelligence`'s
enrichment actor into `JournalStore`, clamping `moodConfidence` into `0...1` since guided
generation is not a hard constraint), `DateRange` helpers (half-open, `calendar`-parameterised
statics for day/week/last-N-days), `EntryDaySection` + `groupedByDay` for list grouping,
`TextStats` (word/character counts), `MoodTrendPoint` for charts.

### Access

- `ReflectModelContainer.make()` / `.makeInMemory()` own the schema.
- `JournalStore: @ModelActor` performs all background reads/writes (enrichment results,
  digest writes, bulk operations) and exposes plain `Sendable` snapshots
  (`EntrySnapshot`) to other modules. Phase 2 added three insight methods, all row-by-row (see
  the `deleteAll` comment below on why batch operations are avoided) and all saving before
  returning:
  - `applyInsight(entryID:draft:) -> EntrySnapshot?` — mutates the entry's existing
    `EntryInsight` in place if one exists (never inserts a second row), otherwise creates one;
    also sets the denormalised `entry.mood`. Never touches `entry.updatedAt` — enrichment is
    not a user edit.
  - `clearInsight(entryID:) -> Bool` — removes the entry's insight (if any) and nils `mood`.
    Used by "Re-analyze" and after a guardrail refusal.
  - `idsNeedingAnalysis(currentVersion:limit:) -> [UUID]` — entries with no insight, an
    insight from an older `analysisVersion`, or an insight generated before the entry's last
    edit, filtered in Swift (not a `#Predicate`) since predicates over an optional to-one
    relationship's properties are a known SwiftData trap.
- Views use `@Query` directly for lists; that is idiomatic SwiftUI and keeps the UI live.
  Single-row swipe deletes go through the view's `@Environment(\.modelContext)` (main actor)
  so `@Query` updates instantly; only bulk operations (`deleteAll`) go through `JournalStore`.

### Isolation

The package compiles with `.defaultIsolation(MainActor.self)`, so every declaration —
including plain `Sendable` structs/enums, not just `@Model` classes — is `@MainActor`
by default unless annotated. `@ModelActor` types run on their own actor, not the main
actor, so anything they read or construct (model classes, and any value type whose
initializer or computed properties they call, e.g. `Mood.score`, `DateRange`,
`MoodTrendPoint`, `EntrySnapshot`, `TextStats`, `groupedByDay`) must be declared
`nonisolated`. `@Model` classes are declared `@Model` then `nonisolated public final class …`
— `nonisolated` must follow the `@Model` attribute, not precede it; putting `nonisolated`
before `@Model` is rejected by macro expansion ("Expected declaration").

### Schema migration policy

Pre-release: **delete and reinstall** during development. `ReflectApp.init()` calls
`ReflectModelContainer.make()` and `fatalError`s if it throws. No `VersionedSchema` /
`SchemaMigrationPlan` exists yet and none is planned until the first TestFlight build, at
which point this section must be updated before any further schema change ships.

## 5. ReflectIntelligence

Phase 2 (done 2026-09-23) implemented the analysis half of this module — mood, summary and
reflection question, streamed. Four deviations from the v1 baseline below, and why:

1. **The streaming protocol carries `AnalysisEvent`/`AnalysisPartial`, not
   `EntryAnalysis.PartiallyGenerated`.** `PartiallyGenerated` refines
   `ConvertibleFromGeneratedContent: SendableMetatype`, which is **not** `Sendable` — it cannot
   cross the actor boundary from `IntelligenceEngine` out to `EnrichmentCoordinator` and
   `ReflectFeatures`. `AnalysisEvent` (`.partial(AnalysisPartial)` / `.finished(AnalysisResult)`)
   is a hand-written `Sendable` value type built from each snapshot instead.
2. **`MoodTag` exists in `ReflectIntelligence` alongside `Mood` in `ReflectDomain`.** `Mood`
   cannot carry `@Generable` — that macro requires `import FoundationModels`, which is banned
   inside `ReflectDomain`. `MoodTag` is the `@Generable` guided-generation vocabulary
   (`veryLow`/`low`/`neutral`/`good`/`great`, no raw values) with `var mood: Mood` and
   `init(_ mood: Mood)` translating immediately after generation.
3. **Phase 2's `EntryAnalysis` carries no `themes`/`actionItems`, and one `.general` request
   replaces the `.contentTagging`/`.general` split.** Theme normalisation, `Theme` upsert and
   the action-item inbox are Phase 3's job, so generating them now would spend context and
   latency on output nothing persists yet. A single `EntryAnalysis` request must pick one
   model, and the request's dominant output is prose, so `.general` is what Phase 2 uses;
   `IntelligenceEngine.init(useCase:)` keeps the `.contentTagging` seam open for Phase 3.
   `AnalysisVersion.current` must bump to `2` when Phase 3 adds them, which automatically makes
   every Phase 2 insight stale via `idsNeedingAnalysis`.
4. **`modelIdentifier` stores the plain string `"system-language-model.general"`, not a
   recorded `SystemLanguageModel.Variant`.** `SystemLanguageModel.variant` is iOS 27-only;
   Phase 2's minimum deployment is iOS 26. Recording the variant behind
   `if #available(iOS 27, *)` is deferred to Phase 4 or 6 rather than adding an availability
   branch for a debug-only field now.

### Public surface (as implemented)

```swift
enum AnalysisEvent: Sendable, Equatable { case partial(AnalysisPartial); case finished(AnalysisResult) }
protocol EntryAnalyzing: Sendable {
    func analyze(_ text: String) async -> AsyncThrowingStream<AnalysisEvent, any Error>
    func prewarm() async
}
enum IntelligenceAvailability  // wraps SystemLanguageModel.Availability
enum IntelligenceError         // app-facing mapping of GenerationError; isRetryable, shouldStoreNoInsight
actor IntelligenceEngine: EntryAnalyzing        // the only place a LanguageModelSession lives
actor EnrichmentCoordinator                     // serial queue: dedup, retry, persists via JournalStore
final class FakeEntryAnalyzer: EntryAnalyzing, Sendable  // scripted, for previews/tests
```

`DigestGenerating`/`ReflectionPrompting` and their `@Generable` schemas are Phase 4's addition,
not yet implemented.

### Generable schema (as implemented)

```swift
@Generable enum MoodTag: Sendable { case veryLow, low, neutral, good, great }  // no raw values

@Generable
struct EntryAnalysis: Sendable {                                    // declaration order = generation order
  @Guide(description: "Overall mood of the writer") var mood: MoodTag
  @Guide(description: "...", .range(0.0...1.0)) var moodConfidence: Double
  @Guide(description: "One sentence, second person, no advice") var summary: String
  @Guide(description: "One open question, no advice, no judgement") var reflectionQuestion: String
}
```

`themes: [ThemeTag]` and `actionItems: [String]` are Phase 3 additions to this schema (see
deviation 3 above). `WeeklyDigestDraft` is Phase 4.

### Engine

- `IntelligenceEngine` is an **actor** owning a single lazily-created `LanguageModelSession`.
  `LanguageModelSession` is not `Sendable` and rejects concurrent requests
  (`GenerationError.concurrentRequests`); `analyze(_:)` chains every call onto one `pending`
  task so exactly one generation runs at a time, making `concurrentRequests` structurally
  impossible rather than merely unlikely.
- `AnalysisBudget.budgeted(_:maxCharacters:)` (8,000 characters ≈ 2,000 tokens) truncates at
  the last paragraph break, falling back to the last whitespace, then a hard prefix, before
  every request — pure and synchronous, no model involvement.
- On `GenerationError.exceededContextWindowSize`, `IntelligenceEngine` retries once with a
  fresh session and half the character budget before giving up and marking the insight
  `isPartial`.
- `session` is set to `nil` in a `defer` after every attempt, so the next entry always starts a
  fresh transcript — there is no multi-turn state worth keeping.
- `prewarm()` creates the session if needed and calls `session.prewarm()`; `ReflectRootView`
  calls it once at launch when `IntelligenceAvailability.current == .available`.

### Coordinator

`EnrichmentCoordinator` is the serial queue between saving an entry and persisting its insight:
FIFO with dedup (same id + identical text while in flight is a no-op; same id + new text
supersedes **and cancels the in-flight run** for that id — `enqueue` cancels `currentTask` and
`process` distinguishes that quiet, expected cancellation from an explicit `cancel(entryID:)`
via a `supersededIDs` marker, which `cancel` itself clears so a cancel landing right after a
supersede still broadcasts a terminal update instead of being silently swallowed), retry with an
injectable delay (`maxAttempts`, default 2), and a broadcast mechanism (`updates(for:) ->
AsyncStream<EnrichmentUpdate>`) that replays the last known update to a late subscriber.
`EnrichmentUpdate.finished` carries the persisted `InsightDraft` itself (not just a bare
completion marker), so an observer — chiefly `InsightPanelModel`, which has no separately-
fetched `EntryInsight` to fall back on in the editor — can render mood/summary/question the
instant analysis completes without the streamed content vanishing.

A `.refused` result stores no insight (`shouldStoreNoInsight`); other retryable errors
(`throttled`, `modelUnavailable`, `malformedOutput`, `unknown`) retry up to `maxAttempts` before
being reported as `.failed`. An `.unknown` error is additionally checked against an injectable
`availability: () -> IntelligenceAvailability` closure (default `{ IntelligenceAvailability.current }`,
overridable in tests): if availability is not `.available` when it occurs, it is demoted to a
non-retryable `.modelUnavailable` rather than burning a second doomed generation attempt — in
practice this override is now largely redundant with `IntelligenceError.init`'s own
domain/code-based classification of the diagnosed missing-assets error (see the error-policy
table below), but remains as a safety net for any other still-unclassified failure while the
model is genuinely unavailable. A failure never removes or alters the entry's text and never
propagates out of the coordinator.

### Tool calling

Not yet implemented — Phase 3. `RecentEntriesTool` and `ThemeHistoryTool` will conform to
`Tool` and read through `JournalStore`, grounding the digest session and the "seen before"
callout in local data.

### Error policy (as implemented — `IntelligenceError`)

| Source error | `IntelligenceError` | `isRetryable` | `shouldStoreNoInsight` |
|---|---|---|---|
| `GenerationError.exceededContextWindowSize` | `contextWindowExceeded` | no (already retried once inside the engine) | no |
| `GenerationError.guardrailViolation`, `.refusal` | `refused` | no | **yes** — show a calm, non-judgemental message, allow manual retry |
| `GenerationError.unsupportedLanguageOrLocale` | `unsupportedLanguage` | no | no |
| `GenerationError.rateLimited`, `.concurrentRequests` | `throttled` | yes | no |
| `GenerationError.assetsUnavailable` | `modelUnavailable` | yes | no |
| `GenerationError.decodingFailure`, `.unsupportedGuide` | `malformedOutput` | yes | no |
| `is CancellationError` | `cancelled` | no | no |
| raw `NSError` matching the diagnosed missing-assets domain/code chain (not a documented `GenerationError` case — see below) | `modelUnavailable` | yes | no |
| anything else undocumented | `unknown` | yes | no |

**Diagnosed missing-assets classification (fix cycle 2):** on a host where
`SystemLanguageModel.default.isAvailable` reports `true` but the on-device model's assets are
not actually installed, real generation requests fail immediately with a raw, undocumented
`NSError` — not a `LanguageModelSession.GenerationError` case — bridged with domain
`FoundationModels.LanguageModelError`, whose underlying-error chain contains
`ModelManagerServices.ModelManagerError` (observed code 1026) and/or
`com.apple.UnifiedAssetFramework` (observed code 5000). `IntelligenceError.init` walks that
chain and matches on domain/code only, **never** on `localizedDescription` or any other string,
so this cannot previously fall through to `.unknown` (a doomed retry storm plus the vaguest
possible copy) — it now reaches the calm "the on-device model isn't ready yet" state
immediately. This is also what lets `LiveEntryAnalysisTests`' capability probe distinguish
"genuinely can't generate here" (skip) from "the engine is broken" (run and fail loudly) — see
§11 and `docs/PLAN.md`'s Phase 2 "Verified" paragraph.

`IntelligenceError.init(_:)` never captures or re-exposes the source error's text/`Context` —
the raw model message never reaches the UI; `InsightPanel` in `ReflectFeatures` owns the
localized copy for every case.

### iOS 27 adoption (behind `#available(iOS 27, *)`)

- `session.usage` / `contextSize` to display token budget in a debug panel and to size chunks.
- `ContextOptions(reasoningLevel:)` for the weekly digest (quality over latency).
- `TranscriptErrorHandlingPolicy.revertTranscript` on the digest session.
- `SystemLanguageModel.Variant` recorded in `EntryInsight.modelIdentifier` (deviation 4 above).
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
| Intelligence | `FakeEntryAnalyzer` for logic; error-mapping tests; live prompt-quality tests over a small golden set of entries, gated by a `CapabilityProbe` that skips only when generation genuinely cannot run here (`!isAvailable` or the diagnosed `.modelUnavailable` case) and otherwise runs and fails loudly. |
| Speech | State machine tests with a fake audio source; live tests skipped in CI. |
| Features | View-model tests with fakes; preview coverage for every screen. |
| App | Xcode UI test target added via Xcode once the flows stabilise (Phase 6). |
