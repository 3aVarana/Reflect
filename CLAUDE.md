# Reflect

Native iOS journaling app. Free-form entries are enriched entirely on-device with Apple's
Foundation Models framework (mood, themes, action items, weekly digest). No backend, no
accounts, no API keys, nothing leaves the phone. Portfolio piece for the iOS 26 on-device
AI stack + SwiftUI + SwiftData (+ HealthKit and WidgetKit in later phases).

Read `docs/ARCHITECTURE.md` before changing module boundaries and `docs/PLAN.md` before
starting a phase. Keep both updated when decisions change.

## Toolchain

- Xcode 27.0, iOS 27.0 SDK, Swift 6.4 toolchain. **Minimum deployment: iOS 26.0.**
  Anything iOS 27-only must be behind `if #available(iOS 27, *)` (see ARCHITECTURE.md).
- Platforms: iPhone + iPad only. Do not re-add macOS/visionOS.
- Swift 6 language mode with default `MainActor` isolation (approachable concurrency) in
  both the app target and the package. Opt out explicitly with `nonisolated`, actors or
  `@ModelActor`; never silence a concurrency error with `@unchecked Sendable`.

## Layout

```
Reflect/                    thin app target: composition root only (ReflectApp.swift, assets)
Packages/ReflectKit/        local Swift package with all real code
  Sources/ReflectDomain        SwiftData models, value types, repositories. No UI, no AI.
  Sources/ReflectIntelligence  Foundation Models: analyzers, @Generable schemas, tools, prompts.
  Sources/ReflectSpeech        SpeechAnalyzer voice capture.
  Sources/ReflectFeatures      SwiftUI screens, @Observable view models, design system.
  Tests/<Module>Tests          Swift Testing suites, one per module.
docs/                       ARCHITECTURE.md, PLAN.md
```

Dependency direction is strictly Features -> Intelligence/Speech -> Domain. The app target
imports only `ReflectDomain` and `ReflectFeatures`.

## Commands

Simulators: use iOS 27.0 runtimes. `iPhone 17` (OS 27.0) is unique by name; several
`iPhone 17 Pro` devices exist across runtimes, so pass `OS=27.0` or a UDID.

```sh
# Build the app
xcodebuild -project Reflect.xcodeproj -scheme Reflect \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' build

# Run all package unit tests (this is where the tests live)
cd Packages/ReflectKit && xcodebuild -scheme ReflectKit-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' test

# Fast type-check of one module without the simulator
cd Packages/ReflectKit && xcodebuild -scheme ReflectDomain -destination 'generic/platform=iOS' build
```

`swift build` at the command line does not work for this package (it needs the iOS SDK
and SwiftUI); always go through `xcodebuild`.

## Conventions

- Foundation Models is only imported inside `ReflectIntelligence`. Features talk to
  protocols (`EntryAnalyzing`, `DigestGenerating`) and app-facing enums
  (`IntelligenceAvailability`), so every screen can be previewed and tested with fakes.
- Raw entry text is the source of truth. All AI output is derived, optional, versioned and
  re-computable. Never block saving an entry on enrichment.
- The app must be fully usable when Apple Intelligence is unavailable; insight surfaces show
  `IntelligenceAvailability.current.message` instead of failing.
- Never use `PrivateCloudComputeLanguageModel`, networking, or analytics. The privacy story
  is the product.
- SwiftData writes off the main actor go through `@ModelActor` types in `ReflectDomain`.
  Views use `@Query`; view models get a `ModelContext` or repository injected.
- Tests use Swift Testing (`@Test`, `#expect`). Tests that call the real model must be gated
  with `.enabled(if: SystemLanguageModel.default.isAvailable)` so CI and ineligible
  machines skip rather than fail.
- Prefer small `@Generable` types with `@Guide` constraints over free-text parsing.
- User-facing strings go through the string catalog (`LOCALIZATION_PREFERS_STRING_CATALOGS`).

## Gotchas

- Foundation Models in the simulator requires the host Mac to have Apple Intelligence
  enabled (System Settings > Apple Intelligence & Siri). Otherwise
  `SystemLanguageModel.default.availability` reports `.unavailable`.
- `LanguageModelSession` is not `Sendable` and rejects concurrent `respond` calls
  (`GenerationError.concurrentRequests`). One session per task, owned by one actor.
- Context window is small (~4k tokens). Long entries and multi-entry digests must be
  chunked or summarized first; catch `exceededContextWindowSize` and start a fresh session.
- The app scheme is shared (`xcshareddata`). `xcuserdata` is git-ignored.
