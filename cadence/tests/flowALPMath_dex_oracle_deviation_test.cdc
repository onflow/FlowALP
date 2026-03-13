import Test
import "FlowALPMath"

access(all) fun setup() {
    let err = Test.deployContract(
        name: "FlowALPMath",
        path: "../lib/FlowALPMath.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all) fun test_dex_oracle_deviation_boundary_exact_threshold() {
    // Exactly at 300 bps (3%) — should pass
    // Oracle: $1.00, DEX: $1.03 → deviation = |1.03-1.00|/1.00 = 3.0% = 300 bps
    var res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 1.03, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(true, res)

    // One basis point over — should fail
    // Oracle: $1.00, DEX: $1.0301 → deviation = 3.01% = 301 bps
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 1.0301, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(false, res)

    // DEX below oracle — exactly at threshold
    // Oracle: $1.00, DEX: $0.97 → deviation = |0.97-1.00|/1.00 = 3.0% = 300 bps
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 0.97, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(true, res)

    // One basis point over on the low side — should fail
    // Oracle: $1.00, DEX: $0.9699 → deviation = |0.9699-1.00|/1.00 = 3.01% = 301 bps
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 0.9699, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(false, res)

    // DEX: $0.971 → deviation = |0.971-1.00|/1.00 = 2.9% = 290 bps
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 0.971, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(true, res)

    // Equal prices — zero deviation — always passes
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 1.0, oraclePrice: 1.0, maxDeviationBps: 0)
    Test.assertEqual(true, res)
}


