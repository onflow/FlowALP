import Test
import BlockchainHelpers

import "MOET"
import "FlowALPModels"
import "test_helpers.cdc"

// Tests that withdrawAndPull pulls from queued (un-credited) deposits before
// touching the position's reserve balance.

access(all) var snapshot: UInt64 = 0

/// Shared pool setup: FLOW token with a small capacity cap (100) and a 50%
/// per-user limit fraction (user limit = 50).  Creating a position with 50 FLOW
/// therefore exhausts the user's allowance, so any subsequent deposit lands
/// entirely in the queue rather than the reserve.
access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 100.0,
        depositCapacityCap: 100.0
    )
    setDepositLimitFraction(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        fraction: 0.5   // user cap = 50 FLOW
    )

    snapshot = getCurrentBlockHeight()
}

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

/// Helper: create a fresh user with 10 000 FLOW, open a 50-FLOW position
/// (exhausting the per-user deposit limit), then queue `queueAmount` FLOW.
/// Returns the user account and the position ID.
access(all)
fun setupPositionWithQueue(queueAmount: UFix64): Test.TestAccount {
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // 50 FLOW accepted into reserve; user is now at the per-user deposit limit.
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // All of queueAmount is queued (user is already at limit).
    depositToPosition(
        signer: user,
        positionID: 0,
        amount: queueAmount,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    return user
}

// -----------------------------------------------------------------------------
// Test 1: Withdrawal entirely from the queue
// When the requested amount is ≤ the queued balance, no reserve tokens should
// be touched: the position's credited balance is unchanged, the reserve balance
// is unchanged, and only the queue shrinks.
// -----------------------------------------------------------------------------
access(all)
fun test_withdraw_fully_from_queue() {
    safeReset()

    let user = setupPositionWithQueue(queueAmount: 100.0)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!
    let pid: UInt64 = 0

    // Sanity-check the setup.
    var queued = getQueuedDeposits(pid: pid, beFailed: false)
    Test.assert(
        equalWithinVariance(100.0, queued[flowType]!, DEFAULT_UFIX_VARIANCE),
        message: "Expected 100 FLOW queued before withdrawal"
    )
    let reserveBefore = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    let creditBefore = getCreditBalanceForType(
        details: getPositionDetails(pid: pid, beFailed: false),
        vaultType: flowType
    )

    // Withdraw 60 FLOW — less than the 100 in the queue.
    let userFlowBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    withdrawFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 60.0,
        pullFromTopUpSource: false
    )

    // User received exactly 60 FLOW.
    let userFlowAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert(
        equalWithinVariance(userFlowBefore + 60.0, userFlowAfter, DEFAULT_UFIX_VARIANCE),
        message: "User should have received 60 FLOW from the queue"
    )

    // Queue shrank by 60 (40 remain).
    queued = getQueuedDeposits(pid: pid, beFailed: false)
    Test.assert(
        equalWithinVariance(40.0, queued[flowType]!, DEFAULT_UFIX_VARIANCE),
        message: "Queue should hold 40 FLOW after withdrawing 60 from it"
    )

    // Reserve balance is unchanged — no tokens left the reserve.
    let reserveAfter = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assert(
        equalWithinVariance(reserveBefore, reserveAfter, DEFAULT_UFIX_VARIANCE),
        message: "Reserve balance should not change when withdrawing from the queue"
    )

    // Position credit balance is unchanged.
    let creditAfter = getCreditBalanceForType(
        details: getPositionDetails(pid: pid, beFailed: false),
        vaultType: flowType
    )
    Test.assert(
        equalWithinVariance(creditBefore, creditAfter, DEFAULT_UFIX_VARIANCE),
        message: "Position credit balance should not change when withdrawing from the queue"
    )
}

// -----------------------------------------------------------------------------
// Test 2: Withdrawal exhausts the queue, remainder comes from the reserve
// When the requested amount exceeds the queued balance, the queue is drained
// first and the shortfall is taken from the reserve.
// -----------------------------------------------------------------------------
access(all)
fun test_withdraw_drains_queue_then_reserve() {
    safeReset()

    let user = setupPositionWithQueue(queueAmount: 100.0)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!
    let pid: UInt64 = 0

    // Withdraw 130 FLOW: 100 from the queue, 30 from the reserve.
    let reserveBefore = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    let creditBefore = getCreditBalanceForType(
        details: getPositionDetails(pid: pid, beFailed: false),
        vaultType: flowType
    )
    let userFlowBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

    withdrawFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 130.0,
        pullFromTopUpSource: false
    )

    // User received 130 FLOW in total.
    let userFlowAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert(
        equalWithinVariance(userFlowBefore + 130.0, userFlowAfter, DEFAULT_UFIX_VARIANCE),
        message: "User should have received 130 FLOW total"
    )

    // Queue is now empty.
    let queued = getQueuedDeposits(pid: pid, beFailed: false)
    Test.assertEqual(UInt64(0), UInt64(queued.length))

    // Reserve decreased by only 30 (the part that wasn't covered by the queue).
    let reserveAfter = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assert(
        equalWithinVariance(reserveBefore - 30.0, reserveAfter, DEFAULT_UFIX_VARIANCE),
        message: "Reserve should decrease by 30 (the non-queued portion)"
    )

    // Position credit balance decreased by 30 only (queue portion had no credit entry).
    let creditAfter = getCreditBalanceForType(
        details: getPositionDetails(pid: pid, beFailed: false),
        vaultType: flowType
    )
    Test.assert(
        equalWithinVariance(creditBefore - 30.0, creditAfter, DEFAULT_UFIX_VARIANCE),
        message: "Position credit balance should decrease by the reserve portion only (30)"
    )
}

// -----------------------------------------------------------------------------
// Test 3: Withdrawal exactly equal to the queued balance
// The queue is drained exactly; the reserve is not touched.
// -----------------------------------------------------------------------------
access(all)
fun test_withdraw_exactly_queue_balance() {
    safeReset()

    let user = setupPositionWithQueue(queueAmount: 80.0)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!
    let pid: UInt64 = 0

    let reserveBefore = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    let userFlowBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

    // Withdraw exactly the queued amount.
    withdrawFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 80.0,
        pullFromTopUpSource: false
    )

    let userFlowAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert(
        equalWithinVariance(userFlowBefore + 80.0, userFlowAfter, DEFAULT_UFIX_VARIANCE),
        message: "User should have received exactly 80 FLOW"
    )

    // Queue is empty.
    let queued = getQueuedDeposits(pid: pid, beFailed: false)
    Test.assertEqual(UInt64(0), UInt64(queued.length))

    // Reserve is untouched.
    let reserveAfter = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assert(
        equalWithinVariance(reserveBefore, reserveAfter, DEFAULT_UFIX_VARIANCE),
        message: "Reserve should be unchanged when withdrawal matches the queued balance exactly"
    )
}

// -----------------------------------------------------------------------------
// Test 4: Normal withdrawal when no queue exists
// Verifies that the existing reserve-only path is unaffected by the change.
// -----------------------------------------------------------------------------
access(all)
fun test_withdraw_no_queue_uses_reserve() {
    safeReset()

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Deposit 50 FLOW (at user limit) — no queue.
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    let pid: UInt64 = 0
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!

    // Confirm no queue.
    let queuedBefore = getQueuedDeposits(pid: pid, beFailed: false)
    Test.assertEqual(UInt64(0), UInt64(queuedBefore.length))

    let reserveBefore = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    let creditBefore = getCreditBalanceForType(
        details: getPositionDetails(pid: pid, beFailed: false),
        vaultType: flowType
    )
    let userFlowBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

    withdrawFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 20.0,
        pullFromTopUpSource: false
    )

    // User received 20 FLOW.
    let userFlowAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert(
        equalWithinVariance(userFlowBefore + 20.0, userFlowAfter, DEFAULT_UFIX_VARIANCE),
        message: "User should have received 20 FLOW from the reserve"
    )

    // Reserve decreased by 20.
    let reserveAfter = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assert(
        equalWithinVariance(reserveBefore - 20.0, reserveAfter, DEFAULT_UFIX_VARIANCE),
        message: "Reserve should decrease by the full 20 when there is no queue"
    )

    // Position credit decreased by 20.
    let creditAfter = getCreditBalanceForType(
        details: getPositionDetails(pid: pid, beFailed: false),
        vaultType: flowType
    )
    Test.assert(
        equalWithinVariance(creditBefore - 20.0, creditAfter, DEFAULT_UFIX_VARIANCE),
        message: "Position credit balance should decrease by 20 when there is no queue"
    )

    // Queue remains empty.
    let queuedAfter = getQueuedDeposits(pid: pid, beFailed: false)
    Test.assertEqual(UInt64(0), UInt64(queuedAfter.length))
}
