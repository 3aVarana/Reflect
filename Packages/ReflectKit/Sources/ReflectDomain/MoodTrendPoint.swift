import Foundation

/// One day's average mood, used for trend charts.
nonisolated public struct MoodTrendPoint: Identifiable, Hashable, Sendable {
    public let day: Date
    public let averageScore: Double
    public let entryCount: Int

    public var id: Date { day }

    public init(day: Date, averageScore: Double, entryCount: Int) {
        self.day = day
        self.averageScore = averageScore
        self.entryCount = entryCount
    }
}
