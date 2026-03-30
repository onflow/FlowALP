import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "FlowALPEvents"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowToken"
import "FungibleToken"

import "test_helpers.cdc"

access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) let user = Test.createAccount()

access(all) let flowBorrowFactor = 1.0
access(all) let flowStartPrice = 1.0
access(all) let positionFundingAmount = 1_000.0

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

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, protocolConsumerAccount)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: flowStartPrice)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.65,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: positionFundingAmount * 4.0)
    snapshot = getCurrentBlockHeight()
}

// -------------------------------------------------------------------------
// Seed pool liquidity / establish a baseline lender position
// -------------------------------------------------------------------------
// Create a separate account (user1) that funds the pool by opening a position
// with a large initial deposit. This ensures the pool has reserves available
// for subsequent borrow/withdraw paths in this test.
access(all)
fun seedPoolLiquidity(amount: UFix64) {
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintFlow(to: lp, amount: amount)
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: lp,
        amount: amount,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
}

access(all)
fun createReentrantSourcePosition(
    signer: Test.TestAccount,
    vaultStoragePath: StoragePath,
    amount: UFix64,
    pushToDrawDownSink: Bool
): Test.TransactionResult {
    return _executeTransaction(
        "./transactions/position-manager/create_position_reentrant_source.cdc",
        [amount, vaultStoragePath, pushToDrawDownSink],
        signer
    )
}

access(all)
fun createReentrantSinkPosition(
    signer: Test.TestAccount,
    amount: UFix64,
    pushToDrawDownSink: Bool
): Test.TransactionResult {
    return _executeTransaction(
        "./transactions/position-manager/create_position_reentrant_sink.cdc",
        [amount, FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink],
        signer
    )
}


access(all)
fun test_reentrancy_recursiveWithdrawSource() {
    safeReset()

    seedPoolLiquidity(amount: 10_000.0)

    // -------------------------------------------------------------------------
    // Attempt a reentrancy / recursive-withdraw scenario
    // -------------------------------------------------------------------------
    // Open a new position for `user` using a special transaction that wires
    // a *malicious* topUpSource (or wrapper behavior) designed to attempt recursion
    // during `withdrawAndPull(..., pullFromTopUpSource: true)`.
    //
    // The goal is to prove the pool rejects the attempt (e.g. via position lock /
    // reentrancy guard), rather than allowing nested withdraw/deposit effects.
    
    let res = createReentrantSourcePosition(
        signer: user,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: positionFundingAmount,
        pushToDrawDownSink: false
    )
    Test.expect(res, Test.beSucceeded())

    // Read the newly opened position id from the latest Opened event.
    let positionID = getLastPositionId()
    log("[TEST] Position opened with ID: \(positionID)")

    // Log balances for debugging context only (not assertions).
    let remainingFlow = getBalance(address: user.address, vaultPublicPath: FLOW_VAULT_PUBLIC_PATH) ?? 0.0
    log("[TEST] User FLOW balance after open: \(remainingFlow)")
    let moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[TEST] User MOET balance after open: \(moetBalance)")


    // -------------------------------------------------------------------------
    // Trigger the vulnerable path: withdraw with pullFromTopUpSource=true
    // -------------------------------------------------------------------------
    // This withdrawal is intentionally oversized so it cannot be satisfied purely
    // from the position’s current available balance. The pool will attempt to pull
    // funds from the configured topUpSource to keep the position above minHealth.
    //
    // In this test, the topUpSource behavior is adversarial: it attempts to re-enter
    // the pool during the pull/deposit flow. We expect the transaction to fail.
        let withdrawRes = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [positionID, FLOW_TOKEN_IDENTIFIER, 1_500.0, true],
        user
    )
    Test.expect(withdrawRes, Test.beFailed())

    // Log post-failure balances for debugging context.
    let currentFlow = getBalance(address: user.address, vaultPublicPath: FLOW_VAULT_PUBLIC_PATH) ?? 0.0
    log("[TEST] User FLOW balance after failed withdraw: \(currentFlow)")
    let currentMoet = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[TEST] User MOET balance after failed withdraw: \(currentMoet)")
}

access(all)
fun test_reentrancy_recursiveDepositSink() {
    safeReset()

    seedPoolLiquidity(amount: 10_000.0)

    // -------------------------------------------------------------------------
    // Attempt a reentrancy / recursive-deposit scenario
    // -------------------------------------------------------------------------
    // Open a new position for `user` using a special transaction that wires
    // a *malicious* drawDownSink designed to attempt recursion during
    // depositAndPush(..., pushToDrawDownSink: true).
    //
    // The goal is to prove the pool rejects the attempt via the position lock /
    // reentrancy guard, rather than allowing nested deposit/withdraw effects.
    //
    // pushToDrawDownSink: false here so position creation succeeds cleanly.
    // The reentrant trigger is the subsequent depositToPosition call below.
    let res = createReentrantSinkPosition(
        signer: user,
        amount: positionFundingAmount,
        pushToDrawDownSink: false
    )
    Test.expect(res, Test.beSucceeded())

    // Read the newly opened position id from the latest Opened event.
    let positionID = getLastPositionId()
    log("[TEST] Position opened with ID: \(positionID)")

    // Log balances for debugging context only (not assertions).
    let remainingFlow = getBalance(address: user.address, vaultPublicPath: FLOW_VAULT_PUBLIC_PATH) ?? 0.0
    log("[TEST] User FLOW balance after open: \(remainingFlow)")
    let moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[TEST] User MOET balance after open: \(moetBalance)")

    // -------------------------------------------------------------------------
    // Trigger the vulnerable path: deposit with pushToDrawDownSink=true
    // -------------------------------------------------------------------------
    // The position already has 1 000 FLOW credit and no debt (health = ∞).
    // Depositing an additional 500 FLOW with pushToDrawDownSink=true keeps it
    // above maxHealth (1.5), so the pool will attempt to push excess value to
    // the configured drawDownSink to bring health back to targetHealth (1.3).
    //
    // attempts to re-enter the pool during the depositCapacity call flow
    // expect the transaction to fail
    let depositRes = _executeTransaction(
        "./transactions/position-manager/deposit_to_position.cdc",
        [positionID, 500.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(depositRes, Test.beFailed())

    // Log post-failure balances for debugging context.
    let currentFlow = getBalance(address: user.address, vaultPublicPath: FLOW_VAULT_PUBLIC_PATH) ?? 0.0
    log("[TEST] User FLOW balance after failed deposit: \(currentFlow)")
    let currentMoet = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[TEST] User MOET balance after failed deposit: \(currentMoet)")
}

// =============================================================================
// Position lock is released after a failed re-entrant transaction
//
// Cadence's post-condition on withdrawAndPull:
//   post { !self.state.isPositionLocked(pid): "Position is not unlocked" }
// guarantees the lock is cleared even on revert.
//
//   maxWithdrawTokens = $100 / (CF * price) = $100 / (0.65 * $1.00) ≈ 153.8 FLOW
//   50 FLOW is safely within that limit.
// =============================================================================
access(all)
fun test_reentrancy_guard_position_lock_released_after_failure() {
    safeReset()

    seedPoolLiquidity(amount: 10_000.0)

    let res = createReentrantSourcePosition(
        signer: user,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 1_000.0,
        pushToDrawDownSink: true
    )
    Test.expect(res, Test.beSucceeded())
    let pid = getLastPositionId()

    // trigger reentrancy — must fail
    let failRes = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [pid, FLOW_TOKEN_IDENTIFIER, 1_500.0, true],
        user
    )
    Test.expect(failRes, Test.beFailed())
    Test.assertError(failRes, errorMessage: "Reentrancy")

    // safe small withdrawal — must succeed, proving lock was released
    withdrawFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 50.0,
        pullFromTopUpSource: false
    )

    // 1000 - 50 = 950 FLOW remaining
    let detailsAfter = getPositionDetails(pid: pid, beFailed: false)
    let flowAfter = getCreditBalanceForType(
        details: detailsAfter,
        vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!
    )
    Test.assertEqual(950.0, flowAfter)
}

// =============================================================================
// No partial writes: all state is rolled back atomically after a blocked re-entrant attempt.
// =============================================================================
access(all)
fun test_reentrancy_state_consistency_no_partial_writes() {
    safeReset()

    seedPoolLiquidity(amount: 10_000.0)

    let res = createReentrantSourcePosition(
        signer: user,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 1_000.0,
        pushToDrawDownSink: true
    )
    Test.expect(res, Test.beSucceeded())
    let pid = getLastPositionId()

    let reserveBefore = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)

    let detailsBefore = getPositionDetails(pid: pid, beFailed: false)
    let creditBefore = getCreditBalanceForType(
        details: detailsBefore,
        vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!
    )
    let moetDebtBefore = getDebitBalanceForType(
        details: detailsBefore,
        vaultType: Type<@MOET.Vault>()
    )
    let FLOWBefore = getBalance(
        address: user.address,
        vaultPublicPath: FLOW_VAULT_PUBLIC_PATH
    ) ?? 0.0

    // trigger re-entrant failure
    let failRes = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [pid, FLOW_TOKEN_IDENTIFIER, 1_500.0, true],
        user
    )
    Test.expect(failRes, Test.beFailed())
    Test.assertEqual(reserveBefore, getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER))

    let detailsAfter = getPositionDetails(pid: pid, beFailed: false)
    let creditAfter = getCreditBalanceForType(
        details: detailsAfter,
        vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!
    )
    Test.assertEqual(creditBefore, creditAfter)

    let moetDebtAfter = getDebitBalanceForType(
        details: detailsAfter,
        vaultType: Type<@MOET.Vault>()
    )
    Test.assertEqual(moetDebtBefore, moetDebtAfter)

    let FLOWAfter = getBalance(
        address: user.address,
        vaultPublicPath: FLOW_VAULT_PUBLIC_PATH
    ) ?? 0.0
    Test.assertEqual(FLOWBefore, FLOWAfter)
}