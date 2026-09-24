import SwiftUI
import ReflectDomain

/// `Mood -> (symbol, tint)` mapping. Lives in `ReflectFeatures` because `ReflectDomain` may
/// not import SwiftUI.
nonisolated extension Mood? {
    var glyphSymbolName: String {
        switch self {
        case .veryLow: "cloud.bolt.rain.fill"
        case .low: "cloud.heavyrain.fill"
        case .neutral: "cloud.sun.fill"
        case .good: "sun.max.fill"
        case .great: "sparkles"
        case nil: "circle.dashed"
        }
    }

    var glyphTint: Color {
        switch self {
        case .veryLow: .indigo
        case .low: .blue
        case .neutral: .gray
        case .good: .orange
        case .great: .yellow
        case nil: .secondary
        }
    }

    var glyphAccessibilityLabel: String {
        switch self {
        case .veryLow: String(localized: "Very low mood", bundle: .module)
        case .low: String(localized: "Low mood", bundle: .module)
        case .neutral: String(localized: "Neutral mood", bundle: .module)
        case .good: String(localized: "Good mood", bundle: .module)
        case .great: String(localized: "Great mood", bundle: .module)
        case nil: String(localized: "Mood not yet detected", bundle: .module)
        }
    }
}

/// A single glyph representing an entry's mood, or a dashed placeholder when there is none
/// yet (no enrichment has run — that is Phase 2).
public struct MoodGlyph: View {
    private let mood: Mood?
    private let size: Font

    public init(mood: Mood?, size: Font = .body) {
        self.mood = mood
        self.size = size
    }

    public var body: some View {
        Image(systemName: mood.glyphSymbolName)
            .font(size)
            .foregroundStyle(mood.glyphTint)
            .accessibilityLabel(mood.glyphAccessibilityLabel)
            .accessibilityHidden(false)
    }
}

#Preview {
    HStack(spacing: Spacing.l) {
        MoodGlyph(mood: .veryLow)
        MoodGlyph(mood: .low)
        MoodGlyph(mood: .neutral)
        MoodGlyph(mood: .good)
        MoodGlyph(mood: .great)
        MoodGlyph(mood: nil)
    }
    .padding()
}
