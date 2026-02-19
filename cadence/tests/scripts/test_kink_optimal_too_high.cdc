import "FlowALPInterestRates"

access(all) fun main() {
    // Should panic: optimalUtilization > 99%
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.995,  // 99.5% > 99%
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )
}
