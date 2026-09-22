import Testing
@testable import ReflectDomain

struct TextStatsTests {
    @Test func emptyStringIsZeroWordsAndCharacters() {
        let stats = TextStats("")
        #expect(stats.words == 0)
        #expect(stats.characters == 0)
        #expect(stats.isEmpty)
    }

    @Test func paddedTextCountsTwoWords() {
        let stats = TextStats("  hello   world  ")
        #expect(stats.words == 2)
    }

    @Test func multiLineStringCountsWordsAcrossNewlines() {
        let stats = TextStats("hello\nworld\nfoo bar")
        #expect(stats.words == 4)
    }

    @Test func charactersCountsRawStringLength() {
        let text = "  hello   world  "
        let stats = TextStats(text)
        #expect(stats.characters == text.count)
    }
}
