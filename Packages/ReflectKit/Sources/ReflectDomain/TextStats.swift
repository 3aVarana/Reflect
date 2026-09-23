import Foundation

/// Word/character counts for an entry's text, used by the editor footer.
nonisolated public struct TextStats: Hashable, Sendable {
    public let words: Int
    public let characters: Int

    public init(_ text: String) {
        self.words = text.split(whereSeparator: \.isWhitespace).count
        self.characters = text.count
    }

    public var isEmpty: Bool { characters == 0 }
}
