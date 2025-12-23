import "FlowCreditMarket"

access(all) fun main() {
    // Should panic: rate > 100%
    FlowCreditMarket.FixedRateInterestCurve(yearlyRate: 1.5)
}
