import "FlowALPInterestRates"

access(all) fun main() {
    // Should panic: slope2 < slope1
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.60,    // slope1 > slope2
        slope2: 0.04     // slope2 < slope1 - should fail
    )
}
