import "FlowALPv1"

access(all) fun main() {
    // Should panic: rate > 100%
    FlowALPv1.FixedRateInterestCurve(yearlyRate: 1.5)
}
