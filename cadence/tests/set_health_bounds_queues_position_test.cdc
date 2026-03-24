import Test
import BlockchainHelpers

import "test_helpers.cdc"

/// Tests that setMinHealth and setMaxHealth queue the position for async update
/// when the new bounds make the current health out-of-range.
///
/// Strategy: verify that asyncUpdate rebalances the position after the setter is called,
/// which only happens if the position was queued. Without the fix, asyncUpdate would be a no-op.
///
/// Default health bounds: minHealth=1.1, targetHealth=1.3, maxHealth=1.5
/// Setup: 100 FLOW collateral, collateralFactor=0.8, price=1.0
///   effectiveCollateral = 80, debt (at targetHealth) = 80/1.3 ≈ 61.538

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
    Test.moveTime(by: 1.0)
}

access(all)
fun beforeEach() {
    Test.reset(to: snapshot)
}

/// Drains the async update queue so all queued positions are processed.
access(all)
fun drainQueue() {
    let res = _executeTransaction(
        "./transactions/flow-alp/pool-management/process_update_queue.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(res, Test.beSucceeded())
}

/// Price of 1.1 → health ≈ 1.43, within (1.1, 1.5).
/// Setting maxHealth to 1.35 (below current health) should queue the position so that
/// asyncUpdate rebalances it back toward targetHealth (1.3).
access(all)
fun test_setMaxHealth_queues_position_when_health_exceeds_new_max() {
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)
    drainQueue()

    // Modest price increase → health ≈ 1.43, still within (1.1, 1.5)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.1)

    let healthBeforeSetter = getPositionHealth(pid: 0, beFailed: false)

    // Lower maxHealth to 1.35 — current health (1.43) now exceeds the new max
    let setRes = _executeTransaction(
        "../transactions/flow-alp/position/set_max_health.cdc",
        [0 as UInt64, 1.35 as UFix64],
        user
    )
    Test.expect(setRes, Test.beSucceeded())

    // asyncUpdate should rebalance the position back toward targetHealth (1.3)
    drainQueue()

    let healthAfter = getPositionHealth(pid: 0, beFailed: false)
    Test.assert(healthAfter < healthBeforeSetter,
        message: "Expected position to be rebalanced toward targetHealth after setMaxHealth + asyncUpdate, but health did not decrease")
}

/// Price of 0.9 → health ≈ 1.17, within (1.1, 1.3).
/// Setting minHealth to 1.2 (above current health) should queue the position so that
/// asyncUpdate rebalances it back toward targetHealth (1.3).
access(all)
fun test_setMinHealth_queues_position_when_health_falls_below_new_min() {
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)
    drainQueue()

    // Modest price drop → health ≈ 1.17, still within (1.1, 1.3)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 0.9)

    let healthBeforeSetter = getPositionHealth(pid: 0, beFailed: false)

    // Raise minHealth to 1.2 — current health (1.17) now falls below the new min
    let setRes = _executeTransaction(
        "../transactions/flow-alp/position/set_min_health.cdc",
        [0 as UInt64, 1.2 as UFix64],
        user
    )
    Test.expect(setRes, Test.beSucceeded())

    // asyncUpdate should rebalance the position back toward targetHealth (1.3)
    drainQueue()

    let healthAfter = getPositionHealth(pid: 0, beFailed: false)
    Test.assert(healthAfter > healthBeforeSetter,
        message: "Expected position to be rebalanced toward targetHealth after setMinHealth + asyncUpdate, but health did not increase")
}
