import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "FlowCreditMarket"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let alice = Test.createAccount()
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    res = setInsuranceRate(
        signer: alice,
        tokenTypeIdentifier: defaultTokenIdentifier,
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let defaultInsuranceRate = 0.0
    var actual = getInsuranceRate(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(defaultInsuranceRate, actual!)

    let insuranceRate = 0.02
    // use protocol account with proper entitlement
    res = setInsuranceRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        insuranceRate: insuranceRate,
    )

    Test.expect(res, Test.beSucceeded())

    actual = getInsuranceRate(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(insuranceRate, actual!)
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate with EGovernance entitlement should fail
// Verifies if swapper is already provided
// -----------------------------------------------------------------------------
access(all)
fun test_set_insuranceRate_without_set_swapper() {
    let res = setInsuranceRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        insuranceRate: 0.01,
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "Cannot set non-zero insurance rate without an insurance swapper configured for \(defaultTokenIdentifier)")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceRate with rate >= 1.0 should fail
// insuranceRate + stabilityFeeRate must be in range [0, 1)
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceRate_rateGreaterThanOne_fails() {
    // set insurance swapper
    var res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let invalidRate = 1.01

    res = setInsuranceRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // first set stability fee rate to 0.6
    res = setStabilityFeeRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        stabilityFeeRate: 0.6,
    )
    Test.expect(res, Test.beSucceeded())

    // now try to set insurance rate to 0.5, which would make combined rate 1.1 >= 1.0
    res = setInsuranceRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // first set insurance rate to 0.6
    res = setInsuranceRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        insuranceRate: 0.6,
    )
    Test.expect(res, Test.beSucceeded())

    // now try to set stability fee rate to 0.5, which would make combined rate 1.1 >= 1.0
    res = setStabilityFeeRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let invalidRate = -0.01

    res = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_insurance_rate.cdc",
        [defaultTokenIdentifier, invalidRate],
        protocolAccount
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let unsupportedTokenIdentifier = flowTokenIdentifier
    res = setInsuranceRate(
        signer: protocolAccount,
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
    let unsupportedTokenIdentifier = flowTokenIdentifier

    let actual = getInsuranceRate(tokenTypeIdentifier: unsupportedTokenIdentifier)

    Test.assertEqual(nil, actual)
}