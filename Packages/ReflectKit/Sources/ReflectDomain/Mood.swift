import Foundation

/// A coarse, five-point mood scale. Deliberately small so the on-device model
/// classifies reliably and the UI can render it as a single glyph or colour.
nonisolated public enum Mood: String, Codable, CaseIterable, Sendable, Hashable {
    case veryLow
    case low
    case neutral
    case good
    case great

    /// Numeric score used for trends and averages (-2 ... +2).
    public var score: Int {
        switch self {
        case .veryLow: -2
        case .low: -1
        case .neutral: 0
        case .good: 1
        case .great: 2
        }
    }
}
