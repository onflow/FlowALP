import "FlowALPv1"

access(all) fun main() {
    // Should panic: base + slope1 + slope2 > 400%
    let curve = FlowALPv1.KinkInterestCurve(
        optimalUtilization: 0.80,
        baseRate: 0.10,   // 10%
        slope1: 0.50,     // 50%
        slope2: 4.00      // 400% -> total = 460% > 400%
    )
}
