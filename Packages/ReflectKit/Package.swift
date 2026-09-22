// swift-tools-version: 6.2
import PackageDescription

/// Shared compiler configuration: Swift 6 language mode with "approachable concurrency"
/// (everything is MainActor-isolated by default; background work opts out explicitly).
let swiftSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "ReflectKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "ReflectDomain", targets: ["ReflectDomain"]),
        .library(name: "ReflectIntelligence", targets: ["ReflectIntelligence"]),
        .library(name: "ReflectSpeech", targets: ["ReflectSpeech"]),
        .library(name: "ReflectFeatures", targets: ["ReflectFeatures"])
    ],
    targets: [
        // Persistence + pure domain types. No UI, no AI.
        .target(name: "ReflectDomain", swiftSettings: swiftSettings),
        // Foundation Models integration: analyzers, generable schemas, tools, prompts.
        .target(name: "ReflectIntelligence", dependencies: ["ReflectDomain"], swiftSettings: swiftSettings),
        // SpeechAnalyzer-based on-device voice capture.
        .target(name: "ReflectSpeech", swiftSettings: swiftSettings),
        // SwiftUI screens, view models and the design system.
        .target(
            name: "ReflectFeatures",
            dependencies: ["ReflectDomain", "ReflectIntelligence", "ReflectSpeech"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "ReflectDomainTests", dependencies: ["ReflectDomain"], swiftSettings: swiftSettings),
        .testTarget(
            name: "ReflectIntelligenceTests",
            dependencies: ["ReflectIntelligence"],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "ReflectFeaturesTests", dependencies: ["ReflectFeatures"], swiftSettings: swiftSettings)
    ],
    swiftLanguageModes: [.v6]
)
