import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
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
}

// -----------------------------------------------------------------------------
// Test: collectInsurance full success flow with formula verification
// Full flow: LP deposits to create credit → borrower borrows to create debit
// → advance time → collect insurance → verify MOET returned, reserves reduced,
// timestamp updated, and formula
// Formula: insuranceAmount = totalDebitBalance * insuranceRate * (timeElapsed / secondsPerYear)
//
// This test runs in isolation (separate file) to ensure totalDebitBalance
// equals exactly the borrowed amount without interference from other tests.
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
    // With 0.8 CF and 1.3 target health: 1000 FLOW collateral allows borrowing ~615 MOET
    // borrow = (collateral * price * CF) / targetHealth = (1000 * 1.0 * 0.8) / 1.3 ≈ 615.38
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1000.0)

    // borrower deposits FLOW and auto-borrows MOET (creates debit balance ~615 MOET)
    createWrappedPosition(signer: borrower, amount: 1000.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: true)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // set 10% annual debit rate
    // insurance is calculated on debit income, not debit balance
    setInterestCurveFixed(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, yearlyRate: 0.1)

    // set insurance rate (10% of debit income)
    let rateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, insuranceRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // collect insurance to reset last insurance collection timestamp,
    // this accounts for timing variation between pool creation and this point
    // (each transaction/script execution advances the block timestamp slightly)
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // record balances after resetting the timestamp
    let initialInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assert(reserveBalanceBefore > 0.0, message: "Reserves should exist after deposit")

    // record timestamp before advancing time
    let timestampBefore = getBlockTimestamp()
    Test.moveTime(by: secondsInYear)

    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance was collected, reserves decreased
    let finalInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assert(reserveBalanceAfter < reserveBalanceBefore, message: "Reserves should have decreased after collection")

    let collectedAmount = finalInsuranceBalance - initialInsuranceBalance

    let amountWithdrawnFromReserves = reserveBalanceBefore - reserveBalanceAfter
    // verify the amount withdrawn from reserves equals the collected amount (1:1 swap ratio)
    Test.assertEqual(amountWithdrawnFromReserves, collectedAmount)

    // verify last insurance collection time was updated to current block timestamp
    let currentTimestamp = getBlockTimestamp()
    let lastInsuranceCollectionTime = getLastInsuranceCollectionTime(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(currentTimestamp, lastInsuranceCollectionTime!)

    // verify formula: insuranceAmount = debitIncome * insuranceRate
    // where debitIncome = totalDebitBalance * (currentDebitRate^timeElapsed - 1.0)
    // debitBalance ≈ 615.38 MOET
    // With 10% annual debit rate over 1 year: debitIncome ≈ 615.38 * (1.105246617130926037773784 - 1) ≈ 64.767
    // Insurance = debitIncome * 0.1 ≈ 6.4767 MOET

    // NOTE:
    // We intentionally do not use `equalWithinVariance` with `defaultUFixVariance` here.
    // The default variance is designed for deterministic math, but insurance collection
    // depends on block timestamps, which can differ slightly between test runs. 
    // A larger, time-aware tolerance is required.
    let tolerance = 0.001
    let expectedCollectedAmount = 6.476
    let diff = expectedCollectedAmount > collectedAmount 
        ? expectedCollectedAmount - collectedAmount
        : collectedAmount - expectedCollectedAmount

    Test.assert(diff < tolerance, message: "Insurance collected should be around \(expectedCollectedAmount) but current \(collectedAmount)")
}
