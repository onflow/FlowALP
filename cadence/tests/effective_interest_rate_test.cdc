import Test
import BlockchainHelpers

import "FlowALPMath"
import "test_helpers.cdc"

access(all)
fun setup() {
    let err = Test.deployContract(
        name: "FlowALPMath",
        path: "../lib/FlowALPMath.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all) struct TestCase {
    access(all) let nominal: UFix128
    access(all) let expected: UFix128

    init(nominal: UFix128, expected: UFix128) {
        self.nominal = nominal
        self.expected = expected
    }
}

access(all)
fun test_effectiveYearlyRate() {
    let delta: UFix128 = 0.0001
    let testCases = [
        TestCase(nominal: 0.01, expected: 0.01005016708),   // ≈ e^0.01 - 1
        TestCase(nominal: 0.02, expected: 0.02020134003),   // ≈ e^0.02 - 1
        TestCase(nominal: 0.05, expected: 0.05127109638),   // ≈ e^0.05 - 1
        TestCase(nominal: 0.50, expected: 0.6487212707),    // ≈ e^0.5  - 1
        TestCase(nominal: 1.0,  expected: 1.7182818285),    // ≈ e^1    - 1
        TestCase(nominal: 4.0,  expected: 53.5981500331)    // ≈ e^4    - 1
    ]
    for testCase in testCases {
        let effective = FlowALPMath.effectiveYearlyRate(nominalYearlyRate: testCase.nominal)
        let diff = effective > testCase.expected ? effective - testCase.expected : testCase.expected - effective
        Test.assert(
            diff <= delta,
            message: "effectiveYearlyRate(\(testCase.nominal.toString())) expected ~\(testCase.expected.toString()), got \(effective.toString()), diff \(diff.toString()) exceeds delta \(delta.toString())"
        )
    }
}
