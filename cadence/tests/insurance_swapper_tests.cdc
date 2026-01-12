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
    let setRes = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: initialPriceRatio,
    )
    Test.expect(setRes, Test.beSucceeded())

    // update to new swapper with different price ratio
    let updatedPriceRatio = 2.0
    let updatedSetRes = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: updatedPriceRatio,
    )
    Test.expect(updatedSetRes, Test.beSucceeded())

    // verify swapper is still configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))
}

// testRemoveInsuranceSwapper verifies setting swapper to nil succeeds
access(all) fun testRemoveInsuranceSwapper() {
    // set a swapper
    let setRes = setInsuranceSwapper(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        priceRatio: 1.0,
    )
    Test.expect(setRes, Test.beSucceeded())

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