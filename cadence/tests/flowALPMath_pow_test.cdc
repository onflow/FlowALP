import Test
import "FlowALPMath"

access(all)
fun setup() {
    let err = Test.deployContract(
        name: "FlowALPMath",
        path: "../lib/FlowALPMath.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all)
fun naivePow(_ base: UFix128, _ exp: UInt64): UFix128 {
    var result: UFix128 = 1.0
    var i: UInt64 = 0
    while i < exp {
        result = result * base
        i = i + 1
    }
    return result
}

access(all)
fun test_pow_zero_exp_returns_one() {
    // Any base with exp=0 should be 1
    let base: UFix128 = 1.23456789
    let out = FlowALPMath.powUFix128(base, 0.0)
    Test.assertEqual(1.0 as UFix128, out)
}

access(all)
fun test_pow_one_base_returns_one() {
    // Base 1 stays 1 for any exponent
    let out = FlowALPMath.powUFix128(1.0, 123.0)
    Test.assertEqual(1.0 as UFix128, out)
}

access(all)
fun test_pow_matches_naive_multiplication_small_exponents() {
    // Spot-check two bases with small integer exponents
    let b1: UFix128 = 1.00000010
    let e1: UInt64 = 10
    let out1 = FlowALPMath.powUFix128(b1, 10.0)
    let exp1 = naivePow(b1, e1)
    Test.assertEqual(exp1, out1)

    let b2: UFix128 = 1.2345
    let e2: UInt64 = 3
    let out2 = FlowALPMath.powUFix128(b2, 3.0)
    let exp2 = naivePow(b2, e2)
    Test.assertEqual(exp2, out2)
}


