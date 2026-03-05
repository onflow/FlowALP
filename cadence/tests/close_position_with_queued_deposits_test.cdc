import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "FlowALPMath"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}
// -----------------------------------------------------------------------------
// Close Position: Queued Deposits & Overpayment Test Suite
//
// Tests that position closure correctly handles:
// 1. Queued deposits that were not yet processed
// 2. Overpayment during debt repayment that becomes collateral
// -----------------------------------------------------------------------------

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
    equalWithinVariance(flowBalanceAfterDeposit, expectedAfterDeposit)

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
    equalWithinVariance(flowBalanceAfter, expectedFinal)

    log("✅ Successfully closed position with queued deposits returned")
}

access(all)
fun test_closePosition_clearsQueuedAsyncUpdateEntry() {
    safeReset()
    // Regression target:
    // A position could remain in `positionsNeedingUpdates` after being closed.
    // Then `asyncUpdate()` would pop that stale pid and panic when trying to
    // update a position that no longer exists.
    //
    // This test recreates that exact sequence and asserts async callbacks
    // succeed after close.
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Keep deposit capacity low so new deposits can overflow active capacity and
    // be queued for async processing (which queues the position id as well).
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 100.0,
        depositCapacityCap: 100.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Step 1: Open a position with a large initial deposit.
    // This consumes full token capacity.
    // The overflow is queued, and the position is put in the async update queue.
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [200.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Step 2: Close the position before async callbacks drain the queue.
    // This is the key condition that previously left a stale pid behind.
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(0)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    // Step 3 (regression assertion): run async update callback.
    // Before the fix, this could panic when touching a removed position.
    // After the fix, stale entries are removed/skipped and callback succeeds.
    let asyncRes = _executeTransaction(
        "./transactions/flow-alp/pool-management/async_update_all.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(asyncRes, Test.beSucceeded())
}

