<<<<<<< HEAD
import "FlowALPInterestRates"

access(all) fun main() {
    // Should panic: optimalUtilization < 1%
    let curve = FlowALPInterestRates.KinkCurve(
=======
import "FlowALPv0"

access(all) fun main() {
    // Should panic: optimalUtilization < 1%
    let curve = FlowALPv0.KinkInterestCurve(
>>>>>>> main
        optimalUtilization: 0.005,  // 0.5% < 1%
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )
}
