# Reflect — Implementation Plan

Each phase ends with a buildable, demoable app. Phases are ordered so the on-device AI story
is visible early (Phase 2) and every later phase adds a distinct showcase capability.
Estimates assume focused solo work.

Legend: **Showcase** = what this phase demonstrates in the portfolio.

---

## Phase 0 — Project foundation ✅ (done 2026-09-22)

- iOS-only target (iPhone + iPad), iOS 26.0 minimum, iOS 27 SDK, Swift 6 + MainActor default.
- Local package `ReflectKit` with `ReflectDomain`, `ReflectIntelligence`, `ReflectSpeech`,
  `ReflectFeatures` and a Swift Testing target per module.
- Shared scheme, `.gitignore`, microphone usage description, `CLAUDE.md`, this plan and
  `docs/ARCHITECTURE.md`.
- Verified: app builds and all package tests pass on iPhone 17 (iOS 27.0) simulator.

---

## Phase 1 — Journal core (Domain + basic UI) · ~2 days

**Goal:** a complete, pleasant journal with no AI at all.

Tasks
- `ReflectDomain`: finish the schema (`EntryInsight`, `Theme`, `ActionItem`, `WeeklyDigest`
  with relationships and cascade rules), `JournalStore` `@ModelActor`, `EntrySnapshot`,
  date-range and mood-trend queries.
- `ReflectFeatures/Journal`: list grouped by day with mood glyph placeholder, search,
  swipe-to-delete, empty state.
- `ReflectFeatures/Editor`: full-screen text editor with autosave (debounced), character
  count, keyboard toolbar.
- `ReflectFeatures/EntryDetail`: read view, edit, delete.
- Adaptive navigation: `TabView` on iPhone, `NavigationSplitView` on iPad.
- Settings screen skeleton with delete-all.

Tests: store insert/update/delete, day grouping, search, cascade delete.

Acceptance
- Create, edit, search and delete entries; data survives relaunch.
- iPad shows list/detail side by side; iPhone uses tabs.

**Showcase:** SwiftData relationships + `@ModelActor`, adaptive SwiftUI navigation.

---

## Phase 2 — Intelligence foundation · ~3 days

**Goal:** every saved entry gets a mood, summary and reflection question, streamed live.

Tasks
- `IntelligenceEngine` actor: session factory with instructions, `prewarm`, one session per
  task, `.contentTagging` for classification and `.general` for prose.
- `@Generable EntryAnalysis` (+ `@Generable Mood`) with `@Guide` constraints.
- `EntryAnalyzing` protocol, live implementation with `streamResponse(generating:)`,
  `FakeEntryAnalyzer` for previews/tests.
- `EnrichmentCoordinator` actor: serial queue, dedup, retry policy, persists results through
  `JournalStore.applyInsight`, records `analysisVersion` + `modelIdentifier`.
- `IntelligenceError` mapping for every `GenerationError` case per ARCHITECTURE §5.
- Editor `InsightPanel` renders `PartiallyGenerated` fields as they arrive; "Re-analyze".
- Availability handling: `IntelligenceAvailability` drives banners; ineligible devices get a
  plain journal with a one-line explanation.
- Chunking for entries over the context budget; insight marked `partial`.

Tests: fake-driven coordinator tests (ordering, dedup, retry), error mapping, gated live
tests over a golden set of ~10 entries asserting mood is in expected range.

Acceptance
- Typing an entry and pausing shows mood, summary and question within a few seconds on a
  device with Apple Intelligence; insight is stored and shown in list and detail.
- Guardrail refusal shows a calm, non-judgemental message and lets the user retry.
- Turning Apple Intelligence off leaves the journal fully functional.

**Showcase:** guided generation, streaming partials, availability + error handling, actor
isolation around a non-Sendable session.

---

## Phase 3 — Themes, action items and tool calling · ~2 days

**Goal:** the app remembers what you keep coming back to.

Tasks
- Theme normalisation (lowercase, singularise light, merge near-duplicates by exact match
  first; fuzzy merge is a stretch goal) and `Theme` upsert in `JournalStore`.
- Action items extracted into `ActionItem` rows; inbox screen with complete/undo, grouped by
  entry date; completed items fade.
- `RecentEntriesTool` and `ThemeHistoryTool` (`Tool` conformances) reading through
  `JournalStore` snapshots.
- "Seen before" callout in `EntryDetail`: after analysis, a second short request with tools
  asks the model to relate this entry to prior mentions of its themes.
- Theme detail screen: entries for a theme over time.

Tests: normalisation table tests, tool argument/return round-trips with a fake store, live
gated test that a tool is invoked for a prompt that needs history.

Acceptance
- Themes accumulate across entries and link back to them.
- Action items are actionable in one place.
- The "seen before" callout cites at least one prior entry when one exists.

**Showcase:** Foundation Models tool calling grounded in local data.

---

## Phase 4 — Weekly digest and trends · ~2–3 days

**Goal:** the Insights tab becomes the reason to open the app on Sunday.

Tasks
- `DigestGenerating` + `@Generable WeeklyDigestDraft`; digest session uses tools from Phase 3
  and, on iOS 27, `ContextOptions(reasoningLevel:)` and `TranscriptErrorHandlingPolicy`.
- `WeeklyDigest` caching by `weekStart`; regenerate when new entries land in that week or
  `analysisVersion` changes; generation runs when the tab appears and on app foreground.
- Mood trend chart (Swift Charts): daily average with interpolation gaps, 7/30/90-day
  ranges, scrubbing with `chartOverlay`.
- Theme timeline (top themes by week) and streak counter.
- Digest card design with headline, narrative, highlights, suggested focus.

Tests: digest cache invalidation, trend aggregation (gaps, timezone boundaries), fake digest
rendering, live gated digest test over a seeded week.

Acceptance
- A week with ≥3 entries yields a digest in under ~10 s on device, cached thereafter.
- Charts are accurate against a hand-computed fixture and are VoiceOver-labelled.

**Showcase:** multi-entry synthesis within a small context window, Swift Charts.

---

## Phase 5 — Voice entries (SpeechAnalyzer) · ~2 days

**Goal:** speak an entry; it is transcribed on-device and enriched like any other.

Tasks
- `VoiceCapture` actor: `AssetInventory` install flow, `AVAudioEngine` tap →
  `AnalyzerInput` stream → `SpeechTranscriber`; volatile vs finalized results.
- Editor microphone button, live transcript with volatile text styled lighter, level meter,
  stop/discard, locale check with a clear unsupported-language message.
- Permission handling and the `preparingAssets` first-run state.
- Entries saved with `source = .voice`; enrichment path unchanged.

Tests: state-machine tests with a fake audio source; transcript merge logic (volatile →
final replacement).

Acceptance
- A 60-second spoken entry becomes text with no network activity and lands in the same
  insight pipeline.

**Showcase:** iOS 26 SpeechAnalyzer, structured concurrency over audio streams.

---

## Phase 6 — Polish, privacy and portfolio readiness · ~2–3 days

- Onboarding: three screens (journal, on-device insight, privacy). Explains behaviour when
  Apple Intelligence is off.
- `PrivacyInfo.xcprivacy`, App Privacy details, no-network grep test in CI.
- Export to JSON via share sheet; delete-all with confirmation.
- Accessibility pass (Dynamic Type, VoiceOver on charts and glyphs, Reduce Motion).
- String catalog, at least one second language to prove the pipeline.
- Performance: `prewarm` timing, Instruments trace of enrichment, memory of streaming.
- App icon, screenshots, README with architecture diagram and a short demo GIF.
- Xcode UI test target (added via Xcode) covering create-entry and insight-visible flows.

Acceptance: App Store-quality build on a physical device; README explains the architecture
in two minutes.

---

## Post-v1 phases (from the original brief)

### Phase 7 — HealthKit
- New `ReflectHealth` module. Write detected mood to HealthKit **State of Mind**
  (`HKStateOfMind`, valence from `Mood.score`, associations from themes) with explicit
  opt-in.
- Read sleep, steps and mindful minutes; compute simple correlations shown in Insights
  ("mood averaged higher after nights with 7h+ sleep"). All computation local.

### Phase 8 — Widgets and App Intents
- `ReflectWidgets` extension: streak, today's mood, a reflection prompt. Data shared through
  an App Group container and `EntrySnapshot`.
- App Intents: "Start a journal entry", "What was my mood this week", Spotlight indexing of
  entries via `CoreSpotlight` (which can consume `@Generable` summaries on iOS 27).

### Phase 9 — Photo journaling (iOS 27)
- Attach a photo to an entry; on iOS 27 pass it as an image `Attachment` so the analysis
  can reference it. Gracefully hidden on iOS 26.

---

## Working agreement

- One phase per branch, merged when its acceptance list passes and tests are green.
- Update `docs/ARCHITECTURE.md` in the same PR as any boundary or schema change.
- Bump `analysisVersion` whenever a prompt or `@Generable` schema changes.
