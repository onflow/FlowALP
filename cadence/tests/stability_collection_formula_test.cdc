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
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with FLOW collateral
    // With 0.8 CF and 1.3 target health: 15000 FLOW collateral allows borrowing ~9231 MOET
    // borrow = (collateral * price * CF) / targetHealth = (15000 * 1.0 * 0.8) / 1.3 ≈ 9230.77
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 15000.0)

    // borrower deposits 15000 FLOW and auto-borrows MOET (creates debit balance ~9231 MOET)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 15000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // set 10% annual debit rate; credit rate = 0.1 × (1 − 0.1) = 0.09
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

    // initialStabilityBalance may be nil if the first collection collected nothing (fee ≈ 0)
    let collectedAmount = (finalStabilityBalance ?? 0.0) - (initialStabilityBalance ?? 0.0)

    let amountWithdrawnFromReserves = reserveBalanceBefore - reserveBalanceAfter
    // With insuranceRate=0 (default), all protocolFee goes to stability, nothing to insurance.
    // So amountWithdrawnFromReserves == stabilityCollected == collectedAmount.
    Test.assertEqual(amountWithdrawnFromReserves, collectedAmount)

    // verify last stability collection time was updated to current block timestamp
    let currentTimestamp = getBlockTimestamp()
    let lastStabilityCollectionTime = getLastStabilityCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(currentTimestamp, lastStabilityCollectionTime!)

    // verify formula (index-based, accounts for credit offset):
    //   protocolFee = debitIncome - creditIncome
    //   stabilityAmount = protocolFee × stabilityFeeRate / totalProtocolFeeRate
    //
    //   debitBalance  ≈ 15000 × 0.8 / 1.3 ≈ 9230.76923077 MOET
    //   creditBalance = 10000 MOET
    //   debitGrowth   = e^0.1 ≈ 1.10517091808
    //   creditGrowth  = e^0.09 ≈ 1.09417428371 (creditRate = debitRate × (1 − 0.1) = 0.09)
    //   debitIncome   = 9230.76923077 × 0.10517091808 ≈ 970.8084
    //   creditIncome  = 10000 × 0.09417428371 ≈ 941.7428
    //   protocolFee   ≈ 29.0656 MOET
    //   stabilityAmt  = 29.0656 × 0.1 / 0.1 = 29.065637485 MOET  (all to stability since insuranceRate=0)
    //
    let expectedCollectedAmount = 29.065
    Test.assert(equalWithinVariance(expectedCollectedAmount, collectedAmount, 0.001), message: "Stability collected should be around \(expectedCollectedAmount) but current \(collectedAmount)")
}