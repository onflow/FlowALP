import "FlowCreditMarket"

access(all) fun main(): Bool {
    // Should panic: optimalUtilization < 1%
    let curve = FlowCreditMarket.KinkInterestCurve(
        optimalUtilization: 0.005,  // 0.5% < 1%
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )
    return true
}
