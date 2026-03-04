import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
}

access(all)
fun test_closePosition_clearsQueuedAsyncUpdateEntry() {
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

    // Step 1: Open a position with a small initial deposit.
    // This consumes part of the token's active capacity.
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [50.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Step 2: Deposit an amount that exceeds remaining active capacity.
    // The overflow is queued, and the position is put in the async update queue.
    let depositRes = _executeTransaction(
        "./transactions/position/deposit_to_position_by_id.cdc",
        [UInt64(0), 150.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    // Step 3: Close the position before async callbacks drain the queue.
    // This is the key condition that previously left a stale pid behind.
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(0)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    // Step 4 (regression assertion): run async update callback.
    // Before the fix, this could panic when touching a removed position.
    // After the fix, stale entries are removed/skipped and callback succeeds.
    let asyncRes = _executeTransaction(
        "./transactions/flow-alp/pool-management/async_update_all.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(asyncRes, Test.beSucceeded())

    // Step 5: run one more callback to prove queue state remains clean.
    let asyncRes2 = _executeTransaction(
        "./transactions/flow-alp/pool-management/async_update_all.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(asyncRes2, Test.beSucceeded())
}
