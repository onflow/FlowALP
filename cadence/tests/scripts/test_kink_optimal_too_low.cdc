import "FlowALPInterestRates"

access(all) fun main() {
    // Should panic: optimalUtilization < 1%
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.005,  // 0.5% < 1%
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )
}
