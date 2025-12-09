import "FlowCreditMarket"

access(all) fun main(): Bool {
    // Should panic: rate > 100%
    let curve = FlowCreditMarket.FixedRateInterestCurve(yearlyRate: 1.5)
    return true
}
