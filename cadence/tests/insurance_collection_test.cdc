import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    // take snapshot first, then advance time so reset() target is always lower than current height
    snapshot = getCurrentBlockHeight()
    Test.moveTime(by: 1.0)
}

access(all)
fun beforeEach() {
     Test.reset(to: snapshot)
}


// -----------------------------------------------------------------------------
// Test: collectInsurance when no swapper is configured should complete without errors
// The collectInsurance function should return nil internally and not fail
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_noSwapper_returnsNil() {
    // setup user
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 1000.0, beFailed: false)

    // create position
    grantPoolCapToConsumer()
    createWrappedPosition(signer: user, amount: 500.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // verify no swapper
    let hasSwapper = _executeScript(
        "../scripts/flow-credit-market/insurance_token_swapper_exists.cdc",
        [defaultTokenIdentifier]
    )
    Test.expect(hasSwapper, Test.beSucceeded())
    Test.assertEqual(false, hasSwapper.returnValue as! Bool)

    // get initial insurance fund balance
    let initialBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialBalance)

    Test.moveTime(by: 86400.0) // 1 day

    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance fund balance is still 0 (no collection occurred)
    let finalBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, finalBalance)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance when totalCreditBalance == 0 should return nil
// When no deposits have been made, totalCreditBalance is 0 and no collection occurs
// Note: This is similar to noReserveVault since both conditions occur together
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_zeroCreditBalance_returnsNil() {
    // setup swapper but DON'T create any positions (no deposits = no credit balance)
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // verify initial insurance fund balance is 0
    let initialBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialBalance)

    Test.moveTime(by: 86400.0) // 1 day

    // collect insurance - should return nil since totalCreditBalance == 0
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance fund balance is still 0 (no collection occurred)
    let finalBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, finalBalance)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance when no time elapsed returns nil
// Even with swapper, reserves, and credit balance, no collection occurs
// if called immediately after a previous collection (timeElapsed == 0)
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_noTimeElapsed_returnsNil() {
    // setup user and create a position with deposit
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 1000.0, beFailed: false)

    // create position with deposit
    grantPoolCapToConsumer()
    createWrappedPosition(signer: user, amount: 500.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // get initial insurance fund balance
    let initialBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialBalance)

    Test.moveTime(by: 86400.0) // 1 day

    // first collection - should succeed and collect insurance
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    let balanceAfterFirst = getInsuranceFundBalance()
    Test.assert(balanceAfterFirst > 0.0, message: "Insurance should have been collected")

    // second collection immediately after - should return nil (no time elapsed)
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // check for no additional collection
    let balanceAfterSecond = getInsuranceFundBalance()
    Test.assertEqual(balanceAfterFirst, balanceAfterSecond)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance only collects up to available reserve balance
// When calculated insurance amount exceeds reserve balance, it collects
// whatever is available
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_partialReserves_collectsAvailable() {
    // setup user and create a position with small deposit
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 1000.0, beFailed: false)

    // create position with deposit - creates reserves
    grantPoolCapToConsumer()
    createWrappedPosition(signer: user, amount: 500.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // set a high insurance rate so calculated amount would exceed reserves
    let rateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, insuranceRate: 1.0) // 100% annual rate
    Test.expect(rateResult, Test.beSucceeded())

    let initialBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialBalance)

    Test.moveTime(by: 31536000.0) // 1 year - at 100% rate this would want to collect 500 MOET
    
    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)

    // collect insurance - should collect up to available reserve balance
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify some insurance was collected
    let finalBalance = getInsuranceFundBalance()
    Test.assert(finalBalance > 0.0, message: "Insurance should have been collected")

    // verify collection was limited by reserve availability
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assert(reserveBalanceAfter < reserveBalanceBefore, message: "Reserves should have decreased")
}

// -----------------------------------------------------------------------------
// Test: collectInsurance when calculated amount rounds to zero returns nil
// Very small time elapsed + small credit balance can result in insuranceAmountUFix64 == 0
// Should return nil and update the lastInsuranceCollection timestamp
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_tinyAmount_roundsToZero_returnsNil() {
    // setup user with a very small deposit
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 1.0, beFailed: false)

    // create position with tiny deposit
    grantPoolCapToConsumer()
    createWrappedPosition(signer: user, amount: 0.00000001, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper with very low rate
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // set a very low insurance rate
    let rateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, insuranceRate: 0.0001) // 0.01% annual
    Test.expect(rateResult, Test.beSucceeded())

    let initialBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialBalance)

    // move time by just 1 second - with tiny balance and low rate, amount should round to 0
    Test.moveTime(by: 1.0)

    // collect insurance - calculated amount should be ~0 due to tiny balance * low rate * short time
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance fund balance is still 0 (amount rounded to 0, no collection)
    let finalBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, finalBalance)
}
