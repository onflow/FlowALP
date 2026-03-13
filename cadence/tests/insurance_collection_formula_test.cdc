import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "test_helpers.cdc"


access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FlowToken as a supported collateral type (needed for borrowing scenarios)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
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
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10000.0, beFailed: false)

    // LP deposits MOET (creates credit balance, provides borrowing liquidity)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with FLOW collateral
    // With 0.8 CF and 1.3 target health: 1000 FLOW collateral allows borrowing ~615 MOET
    // borrow = (collateral * price * CF) / targetHealth = (1000 * 1.0 * 0.8) / 1.3 ≈ 615.38
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1000.0)

    // borrower deposits FLOW and auto-borrows MOET (creates debit balance ~615 MOET)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(PROTOCOL_ACCOUNT, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: PROTOCOL_ACCOUNT.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        swapperInTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        swapperOutTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(swapperResult, Test.beSucceeded())

    // set 10% annual debit rate
    // insurance is calculated on debit income, not debit balance
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.1)

    // set insurance rate (10% of debit income)
    let rateResult = setInsuranceRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, insuranceRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // collect insurance to reset last insurance collection timestamp,
    // this accounts for timing variation between pool creation and this point
    // (each transaction/script execution advances the block timestamp slightly)
    collectInsurance(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // record balances after resetting the timestamp
    let initialInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assert(reserveBalanceBefore > 0.0, message: "Reserves should exist after deposit")

    // record timestamp before advancing time
    let timestampBefore = getBlockTimestamp()
    Test.moveTime(by: ONE_YEAR)

    collectInsurance(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // verify insurance was collected, reserves decreased
    let finalInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assert(reserveBalanceAfter < reserveBalanceBefore, message: "Reserves should have decreased after collection")

    let collectedAmount = finalInsuranceBalance - initialInsuranceBalance

    let amountWithdrawnFromReserves = reserveBalanceBefore - reserveBalanceAfter
    // verify the amount withdrawn from reserves equals the collected amount (1:1 swap ratio)
    Test.assertEqual(amountWithdrawnFromReserves, collectedAmount)

    // verify last insurance collection time was updated to current block timestamp
    let currentTimestamp = getBlockTimestamp()
    let lastInsuranceCollectionTime = getLastInsuranceCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(currentTimestamp, lastInsuranceCollectionTime!)

    // verify formula: insuranceAmount = debitIncome * insuranceRate
    // where debitIncome = totalDebitBalance * (currentDebitRate^timeElapsed - 1.0)
    // = (1.0 + 0.1 / 31_557_600)^31_557_600 = 1.10517091665
    // debitBalance ≈ 615.38 MOET
    // With 10% annual debit rate over 1 year: debitIncome ≈ 615.38 * (1.10517091665 - 1) ≈ 64.72
    // Insurance = debitIncome * 0.1 ≈ 6.472 MOET

    // NOTE:
    // We intentionally do not use `equalWithinVariance` with `defaultUFixVariance` here.
    // The default variance is designed for deterministic math, but insurance collection
    // depends on block timestamps, which can differ slightly between test runs.
    // A larger, time-aware tolerance is required.
    let tolerance = 0.001
    let expectedCollectedAmount = 6.472
    let diff = expectedCollectedAmount > collectedAmount 
        ? expectedCollectedAmount - collectedAmount
        : collectedAmount - expectedCollectedAmount

    Test.assert(diff < tolerance, message: "Insurance collected should be around \(expectedCollectedAmount) but current \(collectedAmount)")
}
