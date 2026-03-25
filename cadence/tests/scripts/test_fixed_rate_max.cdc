import "FlowALPInterestRates"

access(all) fun main() {
    // Should panic: rate > 100%
    FlowALPInterestRates.FixedCurve(yearlyRate: 1.5)
}
