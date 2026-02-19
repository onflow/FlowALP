<<<<<<< HEAD
import "FlowALPInterestRates"

access(all) fun main() {
    // Should panic: slope2 < slope1
    let curve = FlowALPInterestRates.KinkCurve(
=======
import "FlowALPv0"

access(all) fun main() {
    // Should panic: slope2 < slope1
    let curve = FlowALPv0.KinkInterestCurve(
>>>>>>> main
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.60,    // slope1 > slope2
        slope2: 0.04     // slope2 < slope1 - should fail
    )
}
