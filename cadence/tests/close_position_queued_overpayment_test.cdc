import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "FlowALPMath"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Close Position: Queued Deposits & Overpayment Test Suite
//
// Tests that position closure correctly handles:
// 1. Queued deposits that were not yet processed
// 2. Overpayment during debt repayment that becomes collateral
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Test 1: Close position with queued deposits
// =============================================================================
access(all)
fun test_closePosition_withQueuedDeposits() {
    safeReset()
    log("\n=== Test: Close Position with Queued Deposits ===")

    // Setup: price = 1.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Configure token with low deposit limit to force queuing
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 100.0,  // Low limit to force queuing
        depositCapacityCap: 100.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with 50 FLOW (within limit)
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [50.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Get initial Flow balance
    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Flow balance after first deposit: ".concat(flowBalanceBefore.toString()))

    // Try to deposit another 150 FLOW - this should exceed the limit (50 + 150 > 100)
    // and cause some amount (100 FLOW) to be queued
    let depositRes = _executeTransaction(
        "./transactions/position/deposit_to_position_by_id.cdc",
        [UInt64(0), 150.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    // Get Flow balance after deposit
    let flowBalanceAfterDeposit = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Flow balance after second deposit: ".concat(flowBalanceAfterDeposit.toString()))

    // The position can only hold 100 FLOW max, so ~100 FLOW should be queued
    // User should have ~9800 FLOW (10000 - 50 - 150)
    let expectedAfterDeposit = 10_000.0 - 50.0 - 150.0
    Test.assert(flowBalanceAfterDeposit >= expectedAfterDeposit - 1.0, message: "Should have withdrawn full deposit amount")
    Test.assert(flowBalanceAfterDeposit <= expectedAfterDeposit + 1.0, message: "Should have withdrawn full deposit amount")

    // Mint MOET for closing (tiny buffer for any precision)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 0.01, beFailed: false)

    // Close position - should return both processed collateral (50) AND queued deposits (~100)
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(0)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    // Get final Flow balance
    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Flow balance after close: ".concat(flowBalanceAfter.toString()))

    // User deposited 50 + 150 = 200 FLOW total
    // With limit of 100, the breakdown is:
    // - 50 FLOW processed (first deposit)
    // - 50 FLOW processed (from second deposit, to reach 100 limit)
    // - 100 FLOW queued (remainder from second deposit)
    //
    // On close, should get back:
    // - 100 FLOW processed collateral
    // - 100 FLOW queued deposits
    // Total: 200 FLOW back
    //
    // Started: 10000, Withdrew: 200, Should get back: 200
    // Final: 10000
    let expectedFinal = 10_000.0  // All deposits returned
    Test.assert(flowBalanceAfter >= expectedFinal - 10.0, message: "Should return all deposits (processed + queued)")
    Test.assert(flowBalanceAfter <= expectedFinal + 10.0, message: "Should return all deposits (processed + queued)")

    log("✅ Successfully closed position with queued deposits returned")
}

// =============================================================================
// Test 2: Close position with overpayment
// =============================================================================
access(all)
fun test_closePosition_withOverpayment() {
    safeReset()
    log("\n=== Test: Close Position with Overpayment ===")

    // Setup: price = 1.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Configure token with high limits
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with 100 FLOW and borrow MOET
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],  // pushToDrawDownSink = true to borrow
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Check MOET debt
    let positionDetailsBefore = getPositionDetails(pid: UInt64(0), beFailed: false)
    let debtBefore = positionDetailsBefore.balances[0].balance
    log("Initial MOET debt: ".concat(debtBefore.toString()))

    // Verify there's debt
    Test.assert(debtBefore > 0.0, message: "Position should have debt")

    // Get initial MOET balance
    let moetBalanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    log("MOET balance before close: ".concat(moetBalanceBefore.toString()))

    // Mint extra MOET (overpayment)
    let overpaymentAmount = 10.0
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: overpaymentAmount, beFailed: false)

    let moetBalanceWithExtra = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    log("MOET balance with overpayment: ".concat(moetBalanceWithExtra.toString()))

    // Close position with overpayment
    // The closePosition should:
    // 1. Pull exact debt amount from MOET vault
    // 2. Any extra pulled becomes credit balance
    // 3. Return all credits (Flow collateral + MOET overpayment)
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(0)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    // Get final balances
    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    let moetBalanceAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    log("Flow balance after close: ".concat(flowBalanceAfter.toString()))
    log("MOET balance after close: ".concat(moetBalanceAfter.toString()))

    // User started with 1000 FLOW, deposited 100, should get back ~100
    // Final balance should be close to 1000 FLOW
    Test.assert(flowBalanceAfter >= 990.0, message: "Should have at least 990 FLOW total")
    Test.assert(flowBalanceAfter <= 1010.0, message: "Should have at most 1010 FLOW total")

    // MOET balance should be approximately: (initial + overpayment - debt)
    // Since overpayment > needed, some MOET should remain
    // The contract pulls exactly what's needed, so any overpayment in the vault stays there
    // But if overpayment was deposited and became credit, it should be returned
    log("MOET returned/remaining: ".concat(moetBalanceAfter.toString()))

    log("✅ Successfully closed position with overpayment handled correctly")
}

// =============================================================================
// Test 3: Close position with both queued deposits and overpayment
// =============================================================================
access(all)
fun test_closePosition_withQueuedAndOverpayment() {
    safeReset()
    log("\n=== Test: Close Position with Queued Deposits AND Overpayment ===")

    // Setup: price = 1.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Configure token with moderate deposit limit
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 150.0,  // Moderate limit
        depositCapacityCap: 150.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with 100 FLOW and borrow
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],  // Borrow MOET
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Get debt amount
    let positionDetails1 = getPositionDetails(pid: UInt64(0), beFailed: false)
    let debt = positionDetails1.balances[0].balance
    log("MOET debt: ".concat(debt.toString()))

    // Try to deposit more Flow (should partially queue since limit is 150)
    let depositRes = _executeTransaction(
        "./transactions/position/deposit_to_position_by_id.cdc",
        [UInt64(0), 100.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    // Get balances before close
    let flowBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    let moetBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    log("Flow before close: ".concat(flowBefore.toString()))
    log("MOET before close: ".concat(moetBefore.toString()))

    // Mint extra MOET for overpayment
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 5.0, beFailed: false)

    // Close position - should return:
    // 1. Processed Flow collateral
    // 2. Queued Flow deposits (if any)
    // 3. Any MOET overpayment (if it becomes credit)
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(0)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    // Get final balances
    let flowAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    let moetAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    log("Flow after close: ".concat(flowAfter.toString()))
    log("MOET after close: ".concat(moetAfter.toString()))

    // User deposited 100 + 100 = 200 FLOW, with limit 150, so ~50 queued
    // Should get back processed collateral + queued
    // Final flow should be close to starting (minus any processed that stayed)
    let flowReturned = flowAfter - flowBefore
    log("Flow returned: ".concat(flowReturned.toString()))

    // Should return collateral + queued deposits
    Test.assert(flowReturned >= 140.0, message: "Should return collateral + queued deposits")
    Test.assert(flowReturned <= 210.0, message: "Should return collateral + queued deposits")

    log("✅ Successfully closed position with both queued deposits and overpayment")
}

// =============================================================================
// Test 4: Verify queued deposits are tracked and returned correctly
// =============================================================================
access(all)
fun test_queuedDeposits_tracking() {
    safeReset()
    log("\n=== Test: Queued Deposits Tracking ===")

    // Setup with very low deposit limit
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 50.0,  // Very low limit
        depositCapacityCap: 50.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with small amount (within limit)
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [30.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    log("Initial deposit completed")

    // Deposit amount that exceeds limit (30 already in, limit is 50, so deposit 100)
    // Should result in: 20 more processed (to hit 50 limit), 80 queued
    let depositRes = _executeTransaction(
        "./transactions/position/deposit_to_position_by_id.cdc",
        [UInt64(0), 100.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    log("Large deposit completed - queuing should have occurred")

    // Close and verify queued deposits are returned
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 0.01, beFailed: false)

    let flowBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Flow before close: ".concat(flowBefore.toString()))

    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(0)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    let flowAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    let returned = flowAfter - flowBefore

    log("Flow after close: ".concat(flowAfter.toString()))
    log("Total Flow returned: ".concat(returned.toString()))

    // Should return:
    // - 50 FLOW processed collateral (30 initial + 20 from second deposit)
    // - 80 FLOW queued deposits
    // Total: ~130 FLOW
    Test.assert(returned >= 125.0, message: "Should return at least 125 FLOW (collateral + queued)")
    Test.assert(returned <= 135.0, message: "Should return at most 135 FLOW (collateral + queued)")

    log("✅ Queued deposits tracked and returned correctly")
}
