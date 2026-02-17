import "FlowALPv1"

access(all) fun main() {
    // Should panic: optimalUtilization < 1%
    let curve = FlowALPv1.KinkInterestCurve(
        optimalUtilization: 0.005,  // 0.5% < 1%
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )
}
