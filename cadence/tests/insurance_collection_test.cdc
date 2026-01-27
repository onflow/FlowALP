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

    // Add FlowToken as a supported collateral type (needed for borrowing scenarios)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

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
// Test: collectInsurance when no insurance rate is configured should complete without errors
// The collectInsurance function should return nil internally and not fail
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_noInsuranceRate_returnsNil() {
    // setup user
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 1000.0, beFailed: false)

    // create position
    grantPoolCapToConsumer()
    createWrappedPosition(signer: user, amount: 500.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // verify no swapper
    Test.assertEqual(false, insuranceSwapperExists(tokenTypeIdentifier: defaultTokenIdentifier))
    // verify insurance rate
    let insuranceRate = getInsuranceRate(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(0.0, insuranceRate!)

    // get initial insurance fund balance
    let initialBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialBalance)

    Test.moveTime(by: secondsInDay)

    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance fund balance is still 0 (no collection occurred)
    let finalBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, finalBalance)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance when totalDebitBalance == 0 should return nil
// When no deposits have been made, totalDebitBalance is 0 and no collection occurs
// Note: This is similar to noReserveVault since both conditions occur together
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_zeroDebitBalance_returnsNil() {
    // setup swapper but DON'T create any positions
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // verify initial insurance fund balance is 0
    let initialBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialBalance)

    Test.moveTime(by: secondsInDay)

    // collect insurance - should return nil since totalDebitBalance == 0
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance fund balance is still 0 (no collection occurred)
    let finalBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, finalBalance)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance only collects up to available reserve balance
// When calculated insurance amount exceeds reserve balance, it collects
// only what is available. Verify exact amount withdrawn from reserves.
// Note: Insurance is calculated on debit income (interest accrued on debit balance)
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_partialReserves_collectsAvailable() {
    // setup LP to provide MOET liquidity for borrowing (small amount to create limited reserves)
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: protocolAccount, to: lp.address, amount: 1000.0, beFailed: false)
    grantPoolCapToConsumer()

    // LP deposits 1000 MOET (creates credit balance, provides borrowing liquidity)
    createWrappedPosition(signer: lp, amount: 1000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with large FLOW collateral to borrow most of the MOET
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 10000.0)

    // borrower deposits 10000 FLOW and auto-borrows MOET
    // With 0.8 CF and 1.3 target health: 10000 FLOW allows borrowing ~6153 MOET
    // But pool only has 1000 MOET, so borrower gets ~1000 MOET (limited by liquidity)
    // This leaves reserves very low (close to 0)
    createWrappedPosition(signer: borrower, amount: 10000.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: true)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // set 90% annual debit rate
    setInterestCurveFixed(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, yearlyRate: 0.9)

    // set a high insurance rate (90% of debit income goes to insurance)
    // Note: default stabilityFeeRate is 0.05, so insuranceRate + stabilityFeeRate = 0.9 + 0.05 = 0.95 < 1.0
    let rateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, insuranceRate: 0.9)
    Test.expect(rateResult, Test.beSucceeded())

    let initialInsuranceBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialInsuranceBalance)

    Test.moveTime(by: secondsInYear + secondsInDay * 30.0) // year + month

    // collect insurance - should collect up to available reserve balance
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    let finalInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)

    // with 1:1 swap ratio, insurance fund balance should equal amount withdrawn from reserves
    Test.assertEqual(0.0, reserveBalanceAfter)

    // verify collection was limited by reserves
    // Formula: 90% debit income -> 90% insurance rate -> large insurance amount, but limited by available reserves
    Test.assertEqual(1000.0, finalInsuranceBalance)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance when calculated amount rounds to zero returns nil
// Very small time elapsed + small debit balance can result in insuranceAmountUFix64 == 0
// Should return nil and update the last insurance collection timestamp
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
// Full flow: LP deposits to create credit → borrower borrows to create debit
// → advance time → collect insurance → verify MOET returned, reserves reduced, timestamp updated
// Note: Formula verification is in insurance_collection_formula_test.cdc (isolated test)
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_success_fullAmount() {
    // setup LP to provide MOET liquidity for borrowing
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: protocolAccount, to: lp.address, amount: 10000.0, beFailed: false)

    grantPoolCapToConsumer()
    // LP deposits MOET (creates credit balance, provides borrowing liquidity)
    createWrappedPosition(signer: lp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with FLOW collateral
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1000.0)

    // borrower deposits FLOW and auto-borrows MOET (creates debit balance)
    createWrappedPosition(signer: borrower, amount: 1000.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: true)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // set 10% annual debit rate
    // Insurance is calculated on debit income, not debit balance directly
    setInterestCurveFixed(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, yearlyRate: 0.1)

    // set insurance rate (10% of debit income)
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
    Test.assertEqual(amountWithdrawnFromReserves, finalInsuranceBalance)

    // verify last insurance collection time was updated to current block timestamp
    let currentTimestamp = getBlockTimestamp()
    let lastCollectionTime = getLastInsuranceCollectionTime(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(currentTimestamp, lastCollectionTime!)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance with multiple token types
// Verifies that insurance collection works independently for different tokens
// Each token type has its own last insurance collection timestamp and rate
// Note: Insurance is calculated on totalDebitBalance, so we need borrowing activity for each token
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_multipleTokens() {
    // Note: FlowToken is already added in setup()

    // setup MOET LP to provide MOET liquidity for borrowing
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: protocolAccount, to: moetLp.address, amount: 10000.0, beFailed: false)

    grantPoolCapToConsumer()
    // MOET LP deposits MOET (creates MOET credit balance)
    createWrappedPosition(signer: moetLp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup FLOW LP to provide FLOW liquidity for borrowing
    let flowLp = Test.createAccount()
    setupMoetVault(flowLp, beFailed: false)
    transferFlowTokens(to: flowLp, amount: 10000.0)

    // FLOW LP deposits FLOW (creates FLOW debit balance)
    createWrappedPosition(signer: flowLp, amount: 10000.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false)

    // setup MOET borrower with FLOW collateral (creates MOET debit)
    let moetBorrower = Test.createAccount()
    setupMoetVault(moetBorrower, beFailed: false)
    transferFlowTokens(to: moetBorrower, amount: 1000.0)

    // MOET borrower deposits FLOW and auto-borrows MOET (creates MOET debit balance)
    createWrappedPosition(signer: moetBorrower, amount: 1000.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: true)

    // setup FLOW borrower with MOET collateral (creates FLOW debit)
    let flowBorrower = Test.createAccount()
    setupMoetVault(flowBorrower, beFailed: false)
    mintMoet(signer: protocolAccount, to: flowBorrower.address, amount: 1000.0, beFailed: false)

    // FLOW borrower deposits MOET as collateral
    createWrappedPosition(signer: flowBorrower, amount: 1000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // Then borrow FLOW (creates FLOW debit balance)
    borrowFromPosition(signer: flowBorrower, positionId: 3, tokenTypeIdentifier: flowTokenIdentifier, amount: 500.0, beFailed: false)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 20000.0, beFailed: false)

    // configure insurance swappers for both tokens (both swap to MOET at 1:1)
    let moetSwapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(moetSwapperResult, Test.beSucceeded())

    let flowSwapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: flowTokenIdentifier, priceRatio: 1.0)
    Test.expect(flowSwapperResult, Test.beSucceeded())

    // set 10% annual debit rates
    // Insurance is calculated on debit income, not debit balance directly
    setInterestCurveFixed(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, yearlyRate: 0.1)
    setInterestCurveFixed(signer: protocolAccount, tokenTypeIdentifier: flowTokenIdentifier, yearlyRate: 0.1)

    // set different insurance rates for each token type (percentage of debit income)
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
    Test.assertEqual(moetAmountWithdrawn, balanceAfterMoetCollection)

    let moetLastCollectionTime = getLastInsuranceCollectionTime(tokenTypeIdentifier: defaultTokenIdentifier)
    let flowLastCollectionTimeBeforeFlowCollection = getLastInsuranceCollectionTime(tokenTypeIdentifier: flowTokenIdentifier)

    // MOET timestamp should be updated, Flow timestamp should still be at pool creation time
    Test.assert(moetLastCollectionTime != nil, message: "MOET lastInsuranceCollectionTime should be set")
    Test.assert(flowLastCollectionTimeBeforeFlowCollection != nil, message: "Flow lastInsuranceCollectionTime should be set")
    Test.assert(moetLastCollectionTime! > flowLastCollectionTimeBeforeFlowCollection!, message: "MOET timestamp should be newer than Flow timestamp")

    // collect insurance for Flow
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: flowTokenIdentifier, beFailed: false)

    let balanceAfterFlowCollection = getInsuranceFundBalance()
    Test.assert(balanceAfterFlowCollection > balanceAfterMoetCollection, message: "Insurance fund should increase after Flow collection")

    let flowLastCollectionTimeAfter = getLastInsuranceCollectionTime(tokenTypeIdentifier: flowTokenIdentifier)
    Test.assert(flowLastCollectionTimeAfter != nil, message: "Flow lastInsuranceCollectionTime should be set after collection")

    // verify reserves decreased for both token types
    let moetReservesAfter = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    let flowReservesAfter = getReserveBalance(vaultIdentifier: flowTokenIdentifier)
    Test.assert(moetReservesAfter < moetReservesBefore, message: "MOET reserves should have decreased")
    Test.assert(flowReservesAfter < flowReservesBefore, message: "Flow reserves should have decreased")

    // verify the amount withdrawn from Flow reserves equals the insurance fund balance increase (1:1 swap ratio)
    let flowAmountWithdrawn = flowReservesBefore - flowReservesAfter
    let flowInsuranceIncrease = balanceAfterFlowCollection - balanceAfterMoetCollection
    Test.assertEqual(flowAmountWithdrawn, flowInsuranceIncrease)

    // verify Flow timestamp is now updated (should be >= MOET timestamp since it was collected after)
    Test.assert(flowLastCollectionTimeAfter! >= moetLastCollectionTime!, message: "Flow timestamp should be >= MOET timestamp")
}