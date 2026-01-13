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

/* --- Happy Path Tests --- */

// testSetInsuranceSwapper verifies setting a valid insurance swapper succeeds
access(all) fun testSetInsuranceSwapper() {
    // set up a mock swapper that swaps from default token to MOET
    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // verify swapper is configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))
}

// testSetInsuranceSwapper_UpdateExistingSwapper verifies updating an existing swapper succeeds
access(all) fun testSetInsuranceSwapper_UpdateExistingSwapper() {
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

// testRemoveInsuranceSwapper verifies setting swapper to nil succeeds
access(all) fun testRemoveInsuranceSwapper() {
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

/* --- Access Control Tests --- */

// testSetInsuranceSwapper_WithoutEGovernanceEntitlement verifies if account without EGovernance entitlement can set swapper.
access(all) fun testSetInsuranceSwapper_WithoutEGovernanceEntitlement() {
    // non-protocol account tries to set swapper
    let res = setInsuranceSwapper(
        signer: alice,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )

    // should fail due to missing EGovernance entitlement or missing Pool
    Test.expect(res, Test.beFailed())
}

// testSetInsuranceSwapper_WithEGovernanceEntitlement verifies admin can set swapper
access(all) fun testSetInsuranceSwapper_WithEGovernanceEntitlement() {
    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())
}

/* --- Token Type Validation Tests --- */

// testSetInsuranceSwapper_InvalidTokenTypeIdentifier_Fails verifies invalid token identifier fails
access(all) fun testSetInsuranceSwapper_InvalidTokenTypeIdentifier_Fails() {
    let invalidTokenIdentifier = "InvalidTokenType"
    let priceRatio = 1.0

    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: invalidTokenIdentifier,
        priceRatio: 1.0,
    )

    // should fail with "Invalid tokenTypeIdentifier"
    Test.expect(res, Test.beFailed())

    let errorMessage = res.error!.message
    let containsExpectedError = errorMessage.contains("Invalid tokenTypeIdentifier")
    Test.assert(containsExpectedError, message: "expected error about invalid token type identifier, got: \(errorMessage)")
}

// testSetInsuranceSwapper_EmptyTokenTypeIdentifier_Fails verifies empty token identifier fails
access(all) fun testSetInsuranceSwapper_EmptyTokenTypeIdentifier_Fails() {
    let emptyTokenIdentifier = ""

    let res = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: emptyTokenIdentifier,
        priceRatio: 1.0,
    )

    // should fail
    Test.expect(res, Test.beFailed())
    let errorMessage = res.error!.message
    let containsExpectedError = errorMessage.contains("Invalid tokenTypeIdentifier")
    Test.assert(containsExpectedError, message: "expected error about invalid token type identifier, got: \(errorMessage)")
}

/* --- Swapper Type Validation Tests --- */

// testSetInsuranceSwapper_WrongOutputType_Fails verifies swapper must output MOET
access(all) fun testSetInsuranceSwapper_WrongOutputType_Fails() {
    // This test requires a mock swapper that outputs a non-MOET type
    // The contract enforces: swapper.outType() == Type<@MOET.Vault>()

    // try to set a swapper that doesn't output MOET (flowTokenIdentifier)
    let res = _executeTransaction(
        "./transactions/flow-credit-market/pool-governance/set_insurance_swapper_mock.cdc",
        [ defaultTokenIdentifier, 1.0, defaultTokenIdentifier, flowTokenIdentifier],
        protocolAccount
    )

    // should fail with "Swapper output type must be MOET"
    Test.expect(res, Test.beFailed())

    let errorMessage = res.error!.message
    log(errorMessage)
    let containsExpectedError = errorMessage.contains("Swapper output type must be MOET")
    Test.assert(containsExpectedError, message: "expected error about swapper output type, got: \(errorMessage)")
}

// testSetInsuranceSwapper_WrongInputType_Fails verifies swapper input must match token type
access(all) fun testSetInsuranceSwapper_WrongInputType_Fails() {
    // This test requires a mock swapper with mismatched input type
    // The contract enforces: swapper.inType() == tokenType

    // try to set a swapper with wrong input type
    let res = _executeTransaction(
        "./transactions/flow-credit-market/pool-governance/set_insurance_swapper_mock.cdc",
        [defaultTokenIdentifier, 1.0, flowTokenIdentifier, defaultTokenIdentifier],
        protocolAccount
    )
    // should fail with "Swapper input type must match token type"
    Test.expect(res, Test.beFailed())

    let errorMessage = res.error!.message
    let containsExpectedError = errorMessage.contains("Swapper input type must match token type")
    Test.assert(containsExpectedError, message: "expected error about swapper input type, got: \(errorMessage)")
}