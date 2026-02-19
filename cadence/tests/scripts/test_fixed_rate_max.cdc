<<<<<<< HEAD
import "FlowALPInterestRates"

access(all) fun main() {
    // Should panic: rate > 100%
    FlowALPInterestRates.FixedCurve(yearlyRate: 1.5)
=======
import "FlowALPv0"

access(all) fun main() {
    // Should panic: rate > 100%
    FlowALPv0.FixedRateInterestCurve(yearlyRate: 1.5)
>>>>>>> main
}
