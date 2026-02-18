import "FlowALPv0"

access(all) fun main() {
    // Should panic: rate > 100%
    FlowALPv0.FixedRateInterestCurve(yearlyRate: 1.5)
}
