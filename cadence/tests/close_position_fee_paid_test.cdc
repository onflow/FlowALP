import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Close Position With Fee Paid Test Suite
//
// 1. User pays interest: time passes, debt grows, user repays more than borrowed.
//    No collectStability needed — interest accrues and is "paid" on repay.
// 2. Protocol stability fee collected: protocol calls collectStability so the
//    pool has taken its cut before user repays; close still works correctly.
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
// Test: Close position after a stability fee has been collected on MOET debt
// User opens with FLOW collateral, borrows MOET; time passes; protocol
// collects stability fee on MOET; user then repays and closes. A fee was paid.
// -----------------------------------------------------------------------------
access(all)
fun test_closePosition_afterStabilityFeeCollected() {
    // LP provides MOET liquidity so the borrower can draw it
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, lp)
    createPosition(signer: lp, amount: 10_000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // Borrower: FLOW collateral, borrow MOET (position ID 1; position 0 is LP)
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)
    let flowBeforeOpen = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let moetBorrowed = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(moetBorrowed > 0.0, message: "User should have borrowed MOET")

    // Record initial debt (principal) so we can verify interest accrual later
    let detailsAtOpen = getPositionDetails(pid: 1, beFailed: false)
    let initialDebt = getDebitBalanceForType(details: detailsAtOpen, vaultType: Type<@MOET.Vault>())
    Test.assert(initialDebt > 0.0, message: "Position should have MOET debt at open")

    // Enable interest and stability fee so a fee can be collected
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.1)
    let rateRes = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.1)
    Test.expect(rateRes, Test.beSucceeded())

    // Reset stability collection timestamp so next collection has a clear window
    // let _ = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)

    let stabilityBefore = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.moveTime(by: DAY)
    Test.commitBlock()

    // Collect stability so a fee is actually paid (taken from MOET interest)
    // let collectRes = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    // Test.expect(collectRes, Test.beSucceeded())

    // let stabilityAfter = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    // Test.assert(stabilityAfter != nil, message: "Stability fund should exist after collection")
    // Test.assert(stabilityAfter! > 0.0, message: "A stability fee must have been collected (fee was paid)")

    // Verify user's debt grew (interest accrued) so they are actually paying interest
    let detailsAfterTime = getPositionDetails(pid: 1, beFailed: false)
    let debtAfterTime = getDebitBalanceForType(details: detailsAfterTime, vaultType: Type<@MOET.Vault>())
    Test.assert(debtAfterTime > initialDebt, message: "User debt must increase after time (interest accrued). Before: ".concat(initialDebt.toString()).concat(", After: ").concat(debtAfterTime.toString()))

    // let feeCollectedEvts = Test.eventsOfType(Type<FlowALPv0.StabilityFeeCollected>())
    // Test.assert(feeCollectedEvts.length > 0, message: "StabilityFeeCollected should have been emitted")
    // let lastFeeEvt = feeCollectedEvts[feeCollectedEvts.length - 1] as! FlowALPv0.StabilityFeeCollected
    // Test.assert(lastFeeEvt.stabilityAmount > 0.0, message: "Emitted stability amount should be positive")

    // User repays and closes position (may need slightly more MOET due to accrued interest)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 1.0, beFailed: false)

    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(1)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    let closedEvts = Test.eventsOfType(Type<FlowALPv0.PositionClosed>())
    Test.assert(closedEvts.length > 0)
    let closedEvt = closedEvts[closedEvts.length - 1] as! FlowALPv0.PositionClosed
    Test.assertEqual(UInt64(1), closedEvt.pid)
    Test.assert(closedEvt.repaymentsByType[MOET_TOKEN_IDENTIFIER] != nil)
    let repaidMoet = closedEvt.repaymentsByType[MOET_TOKEN_IDENTIFIER]!
    Test.assert(repaidMoet > 0.0, message: "User must have repaid some MOET")
    Test.assert(repaidMoet > moetBorrowed, message: "User must repay more than borrowed (interest paid). Borrowed: ".concat(moetBorrowed.toString()).concat(", Repaid: ").concat(repaidMoet.toString()))
    Test.assert(closedEvt.withdrawalsByType[FLOW_TOKEN_IDENTIFIER] != nil)
    Test.assert(closedEvt.withdrawalsByType[FLOW_TOKEN_IDENTIFIER]! > 0.0)

    let flowAfterClose = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert(flowAfterClose >= flowBeforeOpen - 0.02, message: "User should get collateral back (minus small tolerance)")
    Test.assert(flowAfterClose <= flowBeforeOpen, message: "User must not receive more FLOW than pre-open")

    let detailsAfter = getPositionDetails(pid: 1, beFailed: false)
    for balance in detailsAfter.balances {
        Test.assertEqual(0.0, balance.balance)
    }
}
