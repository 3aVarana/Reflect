import Testing
@testable import ReflectIntelligence

struct IntelligenceAvailabilityTests {
    @Test func everyStateHasAMessage() {
        let states: [IntelligenceAvailability] = [
            .available, .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unavailable,
        ]
        for state in states {
            #expect(!state.message.isEmpty)
        }
    }
}
