import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0
access(all) let flowVaultStoragePath = /storage/flowTokenVault

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
    Test.assertEqual(false, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))

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
    assertEqualWithVariance(balanceAfterFirst, balanceAfterSecond)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance only collects up to available reserve balance
// When calculated insurance amount exceeds reserve balance, it collects
// only what is available. Verify exact amount withdrawn from reserves.
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

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // set a high insurance rate so calculated amount would exceed reserves
    // 100% annual rate on 500 MOET credit = 500 MOET insurance needed per year
    let rateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, insuranceRate: 1.0)
    Test.expect(rateResult, Test.beSucceeded())

    let initialInsuranceBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialInsuranceBalance)

    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assert(reserveBalanceBefore > 0.0, message: "Reserves should exist after deposit")

    Test.moveTime(by: secondsInYear + Fix64(24.0 * 60.0 * 60.0)) // 1 year + 1 day - at 100% rate this would want to collect more than 500 MOET

    // collect insurance - should collect up to available reserve balance
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance was collected
    let finalInsuranceBalance = getInsuranceFundBalance()
    Test.assert(finalInsuranceBalance > 0.0, message: "Insurance should have been collected")

    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)

    // calculate exact amount withdrawn from reserves
    let amountWithdrawnFromReserves = reserveBalanceBefore - reserveBalanceAfter
    Test.assert(amountWithdrawnFromReserves > 0.0, message: "Amount should have been withdrawn from reserves")

    // with 1:1 swap ratio, insurance fund balance should equal amount withdrawn from reserves
    assertEqualWithVariance(amountWithdrawnFromReserves, finalInsuranceBalance)

    // verify collection was limited by reserves
    // Formula: 500.0 * 1.0 * (secondsInYear / secondsInYearPlusDay) ≈ 501.37 MOET, but limited to totalCreditBalance = 500.0
    assertEqualWithVariance(500.0, finalInsuranceBalance)
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

// -----------------------------------------------------------------------------
// Test: collectInsurance full success flow
// Full flow: deposit to create credit → advance time → collect insurance
// → verify MOET returned, reserves reduced, timestamp updated
// Note: Formula verification is in insurance_collection_formula_test.cdc (isolated test)
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_success_fullAmount() {
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

    // set insurance rate
    let rateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, insuranceRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // initial insurance and reserves
    let initialInsuranceBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialInsuranceBalance)
    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assert(reserveBalanceBefore > 0.0, message: "Reserves should exist after deposit")

    Test.moveTime(by: secondsInYear)

    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance was collected, reserves decreased
    let finalInsuranceBalance = getInsuranceFundBalance()
    Test.assert(finalInsuranceBalance > 0.0, message: "Insurance fund should have received MOET")
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assert(reserveBalanceAfter < reserveBalanceBefore, message: "Reserves should have decreased after collection")

    // verify the amount withdrawn from reserves equals the insurance fund balance (1:1 swap ratio)
    let amountWithdrawnFromReserves = reserveBalanceBefore - reserveBalanceAfter
    assertEqualWithVariance(amountWithdrawnFromReserves, finalInsuranceBalance)

    // verify lastInsuranceCollection was updated to current block timestamp
    let currentTimestamp = getBlockTimestamp()
    let lastCollection = getLastInsuranceCollection(tokenTypeIdentifier: defaultTokenIdentifier)
    assertEqualWithVariance(currentTimestamp, lastCollection!)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance with multiple token types
// Verifies that insurance collection works independently for different tokens
// Each token type has its own lastInsuranceCollection timestamp and rate
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_multipleTokens() {
    // set oracle price for FlowToken (needed for collateral factor calculations)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // add FlowToken as a supported collateral type
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // setup users with both token types
    let moetUser = Test.createAccount()
    setupMoetVault(moetUser, beFailed: false)
    mintMoet(signer: protocolAccount, to: moetUser.address, amount: 1000.0, beFailed: false)

    let flowUser = Test.createAccount()
    setupMoetVault(flowUser, beFailed: false)
    transferFlowTokens(to: flowUser, amount: 1000.0)

    // create positions with deposits for both token types
    grantPoolCapToConsumer()
    createWrappedPosition(signer: moetUser, amount: 500.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    createWrappedPosition(signer: flowUser, amount: 500.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 20000.0, beFailed: false)

    // configure insurance swappers for both tokens (both swap to MOET at 1:1)
    let moetSwapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(moetSwapperResult, Test.beSucceeded())

    let flowSwapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: flowTokenIdentifier, priceRatio: 1.0)
    Test.expect(flowSwapperResult, Test.beSucceeded())

    // set different insurance rates for each token type
    let moetRateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, insuranceRate: 0.1) // 10%
    Test.expect(moetRateResult, Test.beSucceeded())

    let flowRateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: flowTokenIdentifier, insuranceRate: 0.05) // 5%
    Test.expect(flowRateResult, Test.beSucceeded())

    // verify initial state
    let initialInsuranceBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialInsuranceBalance)

    let moetReservesBefore = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    let flowReservesBefore = getReserveBalance(vaultIdentifier: flowTokenIdentifier)
    Test.assert(moetReservesBefore > 0.0, message: "MOET reserves should exist after deposit")
    Test.assert(flowReservesBefore > 0.0, message: "Flow reserves should exist after deposit")

    // advance time
    Test.moveTime(by: secondsInYear)

    // collect insurance for MOET only
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    let balanceAfterMoetCollection = getInsuranceFundBalance()
    Test.assert(balanceAfterMoetCollection > 0.0, message: "Insurance fund should have received MOET after MOET collection")

    // verify the amount withdrawn from MOET reserves equals the insurance fund balance increase (1:1 swap ratio)
    let moetAmountWithdrawn = moetReservesBefore - getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    assertEqualWithVariance(moetAmountWithdrawn, balanceAfterMoetCollection)

    let moetLastCollection = getLastInsuranceCollection(tokenTypeIdentifier: defaultTokenIdentifier)
    let flowLastCollectionBeforeFlowCollection = getLastInsuranceCollection(tokenTypeIdentifier: flowTokenIdentifier)

    // MOET timestamp should be updated, Flow timestamp should still be at pool creation time
    Test.assert(moetLastCollection != nil, message: "MOET lastInsuranceCollection should be set")
    Test.assert(flowLastCollectionBeforeFlowCollection != nil, message: "Flow lastInsuranceCollection should be set")
    Test.assert(moetLastCollection! > flowLastCollectionBeforeFlowCollection!, message: "MOET timestamp should be newer than Flow timestamp")

    // collect insurance for Flow
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: flowTokenIdentifier, beFailed: false)

    let balanceAfterFlowCollection = getInsuranceFundBalance()
    Test.assert(balanceAfterFlowCollection > balanceAfterMoetCollection, message: "Insurance fund should increase after Flow collection")

    let flowLastCollectionAfter = getLastInsuranceCollection(tokenTypeIdentifier: flowTokenIdentifier)
    Test.assert(flowLastCollectionAfter != nil, message: "Flow lastInsuranceCollection should be set after collection")

    // verify reserves decreased for both token types
    let moetReservesAfter = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    let flowReservesAfter = getReserveBalance(vaultIdentifier: flowTokenIdentifier)
    Test.assert(moetReservesAfter < moetReservesBefore, message: "MOET reserves should have decreased")
    Test.assert(flowReservesAfter < flowReservesBefore, message: "Flow reserves should have decreased")

    // verify the amount withdrawn from Flow reserves equals the insurance fund balance increase (1:1 swap ratio)
    let flowAmountWithdrawn = flowReservesBefore - flowReservesAfter
    let flowInsuranceIncrease = balanceAfterFlowCollection - balanceAfterMoetCollection
    assertEqualWithVariance(flowAmountWithdrawn, flowInsuranceIncrease)

    // verify Flow timestamp is now updated (should be >= MOET timestamp since it was collected after)
    Test.assert(flowLastCollectionAfter! >= moetLastCollection!, message: "Flow timestamp should be >= MOET timestamp")
}