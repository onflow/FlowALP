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
// Test: collectStability full success flow with formula verification
// Full flow: LP deposits to create credit → borrower borrows to create debit
// → advance time → collect stability → verify tokens returned, reserves reduced,
// timestamp updated, and formula
// Formula: stabilityAmount = interestIncome * stabilityFeeRate
// where interestIncome = totalDebitBalance * (currentDebitRate^timeElapsed - 1.0)
//
// This test runs in isolation (separate file) to ensure totalDebitBalance
// equals exactly the borrowed amount without interference from other tests.
// -----------------------------------------------------------------------------
access(all)
fun test_collectStability_success_fullAmount() {
    // setup LP to provide MOET liquidity for borrowing
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10000.0, beFailed: false)

    // LP deposits MOET (creates credit balance, provides borrowing liquidity)
    createPosition(signer: lp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with FLOW collateral
    // With 0.8 CF and 1.3 target health: 1000 FLOW collateral allows borrowing ~615 MOET
    // borrow = (collateral * price * CF) / targetHealth = (1000 * 1.0 * 0.8) / 1.3 ≈ 615.38
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1000.0)

    // borrower deposits FLOW and auto-borrows MOET (creates debit balance ~615 MOET)
    createPosition(signer: borrower, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // set 10% annual debit rate
    // stability is calculated on interest income, not debit balance directly
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.1)

    // set stability fee rate (10% of interest income)
    let rateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // collect stability to reset last stability collection timestamp,
    // this accounts for timing variation between pool creation and this point
    // (each transaction/script execution advances the block timestamp slightly)
    var res = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    // record balances after resetting the timestamp
    let initialStabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assert(reserveBalanceBefore > 0.0, message: "Reserves should exist after deposit")

    // record timestamp before advancing time
    let timestampBefore = getBlockTimestamp()
    Test.moveTime(by: ONE_YEAR)

    res = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    // verify stability was collected, reserves decreased
    let finalStabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assert(reserveBalanceAfter < reserveBalanceBefore, message: "Reserves should have decreased after collection")

    let collectedAmount = finalStabilityBalance! - initialStabilityBalance!

    let amountWithdrawnFromReserves = reserveBalanceBefore - reserveBalanceAfter
    // verify the amount withdrawn from reserves equals the collected amount
    Test.assertEqual(amountWithdrawnFromReserves, collectedAmount)

    // verify last stability collection time was updated to current block timestamp
    let currentTimestamp = getBlockTimestamp()
    let lastStabilityCollectionTime = getLastStabilityCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(currentTimestamp, lastStabilityCollectionTime!)

    // verify formula: stabilityAmount = interestIncome * stabilityFeeRate
    // where interestIncome = totalDebitBalance * (currentDebitRate^timeElapsed - 1.0) 
    // = (1.0 + 0.1 / 31_557_600)^31_557_600 = 1.10517091665
    // debitBalance ≈ 615.38 MOET
    // With 10% annual debit rate over 1 year: interestIncome ≈ 615.38 * (1.10517091665 - 1) ≈ 64.72
    // Stability = interestIncome * 0.1 ≈ 6.472 MOET
    
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

    Test.assert(diff < tolerance, message: "Stability collected should be around \(expectedCollectedAmount) but current \(collectedAmount)")
}