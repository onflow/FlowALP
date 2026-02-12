import "FlowALPRateCurves"

access(all) fun main() {
    // Should panic: rate > 100%
    FlowALPRateCurves.FixedRateInterestCurve(yearlyRate: 1.5)
}
