import Test

import "test_helpers.cdc"
import "FlowCreditMarket"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let alice = Test.createAccount()

access(all)
fun setup() {
    deployContracts()
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: defaultTokenIdentifier, price: 1.0)
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with valid configuration should succeed
// Verifies that a valid insurance swapper can be set for a token type
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_success() {
    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // verify swapper is configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper can update existing swapper
// Verifies that an existing swapper can be replaced with a new one
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_updateExistingSwapper_success() {
    // set initial swapper
    let initialPriceRatio = 1.0
    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: initialPriceRatio,
    )
    Test.expect(res, Test.beSucceeded())

    // update to new swapper with different price ratio
    let updatedPriceRatio = 2.0
    let updatedRes = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: updatedPriceRatio,
    )
    Test.expect(updatedRes, Test.beSucceeded())

    // verify swapper is still configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))
}

// -----------------------------------------------------------------------------
// Test: removeInsuranceSwapper should remove configured swapper
// Verifies that an insurance swapper can be removed after being set
// -----------------------------------------------------------------------------
access(all)
fun test_removeInsuranceSwapper_success() {
    // set a swapper
    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // verify swapper is configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))

    // remove swapper
    let removeResult = removeInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
    )
    Test.expect(removeResult, Test.beSucceeded())

    // verify swapper is no longer configured
    Test.assertEqual(false, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))
}

// -----------------------------------------------------------------------------
// Test: test_remove_insuranceSwapper_failed should not remove configured swapper
// Verifies that an insurance swapper cannot be removed when insurance rate is being set
// -----------------------------------------------------------------------------
access(all)
fun test_remove_insuranceSwapper_failed() {
    // set a swapper
    var res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // verify swapper is configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))

    // set insurance rate
    res = setInsuranceRate(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        insuranceRate: 0.001,
    )
    Test.expect(res, Test.beSucceeded())

    // remove swapper
    let removeResult = removeInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
    )
    Test.expect(removeResult, Test.beFailed())

    let errorMessage = removeResult.error!.message
    let containsExpectedError = errorMessage.contains("Cannot remove insurance swapper while insurance rate is non-zero for \(defaultTokenIdentifier)")
    Test.assert(containsExpectedError, message: "expected error about cannot remove insurance swapper, got: \(errorMessage)")

    // verify swapper is still exist
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper without EGovernance entitlement should fail
// Verifies that accounts without EGovernance entitlement cannot set swapper
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_withoutEGovernanceEntitlement_fails() {
    let res = setInsuranceSwapper(
        signer: alice,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )

    // should fail due to missing EGovernance entitlement or missing Pool
    Test.expect(res, Test.beFailed())
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with EGovernance entitlement should succeed
// Verifies that admin with proper entitlement can set swapper
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_withEGovernanceEntitlement_success() {
    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with invalid token identifier should fail
// Verifies that non-existent token types are rejected
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_invalidTokenTypeIdentifier_fails() {
    let invalidTokenIdentifier = "InvalidTokenType"

    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: invalidTokenIdentifier,
        priceRatio: 1.0,
    )

    Test.expect(res, Test.beFailed())

    let errorMessage = res.error!.message
    let containsExpectedError = errorMessage.contains("Invalid tokenTypeIdentifier")
    Test.assert(containsExpectedError, message: "expected error about invalid token type identifier, got: \(errorMessage)")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with empty token identifier should fail
// Verifies that empty string token identifiers are rejected
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_emptyTokenTypeIdentifier_fails() {
    let emptyTokenIdentifier = ""

    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: emptyTokenIdentifier,
        priceRatio: 1.0,
    )

    Test.expect(res, Test.beFailed())

    let errorMessage = res.error!.message
    let containsExpectedError = errorMessage.contains("Invalid tokenTypeIdentifier")
    Test.assert(containsExpectedError, message: "expected error about invalid token type identifier, got: \(errorMessage)")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with wrong output type should fail
// Swapper must output MOET (insurance fund denomination)
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_wrongOutputType_fails() {
    // try to set a swapper that doesn't output MOET (outputs flowTokenIdentifier instead)
    let res = _executeTransaction(
        "./transactions/flow-credit-market/pool-governance/set_insurance_swapper_mock.cdc",
        [defaultTokenIdentifier, 1.0, defaultTokenIdentifier, flowTokenIdentifier],
        protocolAccount
    )

    Test.expect(res, Test.beFailed())

    let errorMessage = res.error!.message
    let containsExpectedError = errorMessage.contains("Swapper output type must be MOET")
    Test.assert(containsExpectedError, message: "expected error about swapper output type, got: \(errorMessage)")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with wrong input type should fail
// Swapper input type must match the token type being configured
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_wrongInputType_fails() {
    // try to set a swapper with wrong input type (flowTokenIdentifier instead of defaultTokenIdentifier)
    let res = _executeTransaction(
        "./transactions/flow-credit-market/pool-governance/set_insurance_swapper_mock.cdc",
        [defaultTokenIdentifier, 1.0, flowTokenIdentifier, defaultTokenIdentifier],
        protocolAccount
    )

    Test.expect(res, Test.beFailed())

    let errorMessage = res.error!.message
    let containsExpectedError = errorMessage.contains("Swapper input type must match token type")
    Test.assert(containsExpectedError, message: "expected error about swapper input type, got: \(errorMessage)")
}