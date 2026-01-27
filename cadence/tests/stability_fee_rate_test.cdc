import Test

import "test_helpers.cdc"
import "FlowCreditMarket"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let alice = Test.createAccount()


access(all)
fun setup() {
    deployContracts()

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
}

/* --- Access Control Tests --- */

// test_set_stability_fee_rate_without_EGovernance_entitlement verifies if account without EGovernance entitlement can set stability fee rate.
access(all) fun test_set_stability_fee_rate_without_EGovernance_entitlement() {
    let res= setStabilityFeeRate(
        signer: alice,
        tokenTypeIdentifier: defaultTokenIdentifier,
        stabilityFeeRate: 0.07,
    )

    // should fail due to missing EGovernance entitlement
    Test.expect(res, Test.beFailed())
}

// test_set_stability_fee_rate_with_EGovernance_entitlement verifies the function requires proper EGovernance entitlement can set stability fee rate.
access(all) fun test_set_stability_fee_rate_with_EGovernance_entitlement() {
    let defaultStabilityFeeRate = 0.05
    var actual = getStabilityFeeRate(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(defaultStabilityFeeRate, actual!)

    let newStabilityFeeRate = 0.01
    // use protocol account with proper entitlement
    let res = setStabilityFeeRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        stabilityFeeRate: newStabilityFeeRate,
    )

    Test.expect(res, Test.beSucceeded())

    actual = getStabilityFeeRate(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(newStabilityFeeRate, actual!)
}

/* --- Boundary Tests: stability fee rate must be between 0 and 1 --- */

// test_set_stability_fee_rate_greater_than_one_fails verifies that setting a stability fee rate greater than 1.0 (100%) fails.
access(all) fun test_set_stability_fee_rate_greater_than_one_fails() {
    // rate > 1.0 violates precondition
    let invalidFeeRate = 1.01

    let res = setStabilityFeeRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        stabilityFeeRate: invalidFeeRate,
    )
    // should fail with "stability fee rate must be between 0 and 1"
    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "stability fee rate must be in range [0, 1)")
}


// test_set_stability_fee_rate_less_than_zero_fails verifies that setting a negative stability fee rate fails.
access(all) fun test_set_stability_fee_rate_less_than_zero_fails() {
    // rate < 0
    let invalidRate = -0.01

    let res = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_stability_fee_rate.cdc",
        [defaultTokenIdentifier, invalidRate],
        protocolAccount
    )

    // should fail with "expected value of type UFix64"
    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "invalid argument at index 1: expected value of type `UFix64`")
}

/* --- Token Type Tests --- */
// test_set_stability_fee_rate_invalid_token_type_fails verifies that setting stability fee rate for an unsupported token type fails.
access(all) fun test_set_stability_fee_rate_invalid_token_type_fails() {    
    let unsupportedTokenIdentifier = flowTokenIdentifier
    let res = setStabilityFeeRate(
        signer: protocolAccount,
        tokenTypeIdentifier: unsupportedTokenIdentifier,
        stabilityFeeRate: 0.05,
    )
    // should fail with "Unsupported token type"
    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "Unsupported token type")
}

// test_get_stability_fee_rate_invalid_token_type that getStabilityFeeRate returns nil for unsupported token types.
access(all) fun test_get_stability_fee_rate_invalid_token_type() {
    let unsupportedTokenIdentifier = flowTokenIdentifier

    let actual = getStabilityFeeRate(tokenTypeIdentifier: unsupportedTokenIdentifier)
    // should return nil for unsupported token type identifier
    Test.assertEqual(nil, actual)
}

// test_setStabilityFeeRate_emits_event verifies that the StabilityFeeRateUpdated event is emitted with correct parameters
// when the stability fee rate is successfully updated.
access(all) fun test_set_stability_fee_rate_emits_event() {
    let newRate = 0.08

    let res = setStabilityFeeRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        stabilityFeeRate: newRate,
    )

    Test.expect(res, Test.beSucceeded())

    // Verify event emission
    let events = Test.eventsOfType(Type<FlowCreditMarket.StabilityFeeRateUpdated>())
    Test.assert(events.length > 0, message: "Expected StabilityFeeRateUpdated event to be emitted")

    let stabilityFeeRateUpdatedEvent = events[events.length - 1] as! FlowCreditMarket.StabilityFeeRateUpdated
    Test.assertEqual(defaultTokenIdentifier, stabilityFeeRateUpdatedEvent.tokenType)
    Test.assertEqual(newRate, stabilityFeeRateUpdatedEvent.stabilityFeeRate)
}