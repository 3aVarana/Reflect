import Testing
@testable import ReflectIntelligence

struct AnalysisBudgetTests {
    @Test func shortTextPassesThroughUnchanged() {
        let (text, wasTruncated) = AnalysisBudget.budgeted("A short entry.", maxCharacters: 8_000)
        #expect(text == "A short entry.")
        #expect(wasTruncated == false)
    }

    @Test func longTextIsCutAtAParagraphBreakAtOrBelowTheLimit() {
        let paragraph = String(repeating: "a", count: 100)
        let text = Array(repeating: paragraph, count: 100).joined(separator: "\n\n")
        #expect(text.count > 1_000)

        let (budgeted, wasTruncated) = AnalysisBudget.budgeted(text, maxCharacters: 1_000)
        #expect(wasTruncated == true)
        #expect(budgeted.count <= 1_000)
        // The cut must land exactly at a paragraph boundary: what remains, followed by "\n\n",
        // must be a prefix of the original text.
        #expect(text.hasPrefix(budgeted + "\n\n"))
    }

    @Test func textWithNoBreakFallsBackToAHardPrefix() {
        let text = String(repeating: "a", count: 10_000)
        let (budgeted, wasTruncated) = AnalysisBudget.budgeted(text, maxCharacters: 8_000)
        #expect(wasTruncated == true)
        #expect(budgeted.count == 8_000)
        #expect(budgeted == String(repeating: "a", count: 8_000))
    }

    @Test func textWithOnlyWhitespaceBreaksFallsBackToLastWhitespace() {
        let text = String(repeating: "a", count: 500) + " " + String(repeating: "b", count: 500)
        let (budgeted, wasTruncated) = AnalysisBudget.budgeted(text, maxCharacters: 700)
        #expect(wasTruncated == true)
        #expect(budgeted.count <= 700)
        #expect(budgeted == String(repeating: "a", count: 500))
    }

    @Test func emptyStringIsSafe() {
        let (budgeted, wasTruncated) = AnalysisBudget.budgeted("", maxCharacters: 8_000)
        #expect(budgeted == "")
        #expect(wasTruncated == false)
    }
}
