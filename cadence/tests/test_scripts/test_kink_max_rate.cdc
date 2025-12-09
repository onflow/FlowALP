import "FlowCreditMarket"

access(all) fun main(): Bool {
    // Should panic: base + slope1 + slope2 > 400%
    let curve = FlowCreditMarket.KinkInterestCurve(
        optimalUtilization: 0.80,
        baseRate: 0.10,   // 10%
        slope1: 0.50,     // 50%
        slope2: 4.00      // 400% -> total = 460% > 400%
    )
    return true
}
