import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "FlowALPv0"

access(all) let alice = Test.createAccount()
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    
    // take snapshot first, then advance time so reset() target is always lower than current height
    snapshot = getCurrentBlockHeight()
    // move time by 1 second so Test.reset() works properly before each test
    Test.moveTime(by: 1.0)
}

access(all)
fun beforeEach() {
     Test.reset(to: snapshot)
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate without EGovernance entitlement should fail
// Verifies that accounts without EGovernance entitlement cannot set insurance rate
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceRate_withoutEGovernanceEntitlement() {
    // set insurance swapper
    var res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    res = setInsuranceRate(
        signer: alice,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.01,
    )

    // should fail due to missing EGovernance entitlement
    Test.expect(res, Test.beFailed())
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate with EGovernance entitlement should succeed
// Verifies the function requires proper EGovernance entitlement and updates rate
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceRate_withEGovernanceEntitlement() {
    // set insurance swapper
    var res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let defaultInsuranceRate = 0.0
    var actual = getInsuranceRate(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(defaultInsuranceRate, actual!)

    let insuranceRate = 0.02
    // use protocol account with proper entitlement
    res = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: insuranceRate,
    )

    Test.expect(res, Test.beSucceeded())

    actual = getInsuranceRate(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(insuranceRate, actual!)
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate with EGovernance entitlement should fail when no swapper is configured.
// Verifies if swapper is already provided
// -----------------------------------------------------------------------------
access(all)
fun test_set_insuranceRate_without_set_swapper() {
    let res = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.01,
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "Cannot set non-zero insurance rate without an insurance swapper configured for \(MOET_TOKEN_IDENTIFIER)")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate with rate >= 1.0 should fail
// insuranceRate + stabilityFeeRate must be in range [0, 1)
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceRate_rateGreaterThanOne_fails() {
    // set insurance swapper
    var res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let invalidRate = 1.01

    res = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: invalidRate,
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "insuranceRate must be in range [0, 1)")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate fails when combined with stabilityFeeRate >= 1.0
// insuranceRate + stabilityFeeRate must be in range [0, 1) to avoid underflow
// in credit rate calculation: creditRate = debitRate * (1.0 - protocolFeeRate)
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceRate_combinedRateExceedsOne_fails() {
    // set insurance swapper
    var res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // first set stability fee rate to 0.6
    res = setStabilityFeeRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        stabilityFeeRate: 0.6,
    )
    Test.expect(res, Test.beSucceeded())

    // now try to set insurance rate to 0.5, which would make combined rate 1.1 >= 1.0
    res = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.5,
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "insuranceRate + stabilityFeeRate must be in range [0, 1)")
}

// -----------------------------------------------------------------------------
// Test: setStabilityFeeRate fails when combined with insuranceRate >= 1.0
// stabilityFeeRate + insuranceRate must be in range [0, 1) to avoid underflow
// -----------------------------------------------------------------------------
access(all)
fun test_setStabilityFeeRate_combinedRateExceedsOne_fails() {
    // set insurance swapper
    var res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // first set insurance rate to 0.6
    res = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.6,
    )
    Test.expect(res, Test.beSucceeded())

    // now try to set stability fee rate to 0.5, which would make combined rate 1.1 >= 1.0
    res = setStabilityFeeRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        stabilityFeeRate: 0.5,
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "stabilityFeeRate + insuranceRate must be in range [0, 1)")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate with rate < 0 should fail
// Negative rates are invalid (UFix64 constraint)
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceRate_rateLessThanZero_fails() {
    // set insurance swapper
    var res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let invalidRate = -0.01

    res = _executeTransaction(
        "../transactions/flow-alp/pool-governance/set_insurance_rate.cdc",
        [MOET_TOKEN_IDENTIFIER, invalidRate],
        PROTOCOL_ACCOUNT
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "invalid argument at index 1: expected value of type `UFix64`")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate with unsupported token type should fail
// Only supported tokens can have insurance rates configured
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceRate_invalidTokenType_fails() {
    // set insurance swapper
    var res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let unsupportedTokenIdentifier = FLOW_TOKEN_IDENTIFIER
    res = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: unsupportedTokenIdentifier,
        insuranceRate: 0.05,
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "Unsupported token type")
}

// -----------------------------------------------------------------------------
// Test: getInsuranceRate for unsupported token type returns nil
// Query for non-existent token should return nil, not fail
// -----------------------------------------------------------------------------
access(all)
fun test_getInsuranceRate_invalidTokenType_returnsNil() {
    let unsupportedTokenIdentifier = FLOW_TOKEN_IDENTIFIER

    let actual = getInsuranceRate(tokenTypeIdentifier: unsupportedTokenIdentifier)

    Test.assertEqual(nil, actual)
}
