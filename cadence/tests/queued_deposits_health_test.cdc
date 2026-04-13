import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

// Tests that queued deposits are counted when determining whether a position is
// liquidatable or needs rebalancing.

access(all) var snapshot: UInt64 = 0

// Pool setup:
// - FLOW: cf=0.8, bf=1.0, depositCapacityCap=1000, depositRate=1.0/s, limitFraction=1.0
//   This means one position can deposit up to 1000 FLOW before the cap is hit.
//   A second deposit lands entirely in the queue until capacity regenerates.
// - DEX: FLOW→MOET at 0.7 (used by liquidation tests)
access(all)
fun setup() {
    deployContracts()
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1.0,         // 1 FLOW/s regeneration — not advanced in tests
        depositCapacityCap: 1000.0
    )
    setDepositLimitFraction(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        fraction: 1.0
    )
    setMockDexPriceForPair(
        signer: PROTOCOL_ACCOUNT,
        inVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        outVaultIdentifier: MOET_TOKEN_IDENTIFIER,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: 0.7
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

// Helper: create a user with FLOW, open a 1000-FLOW position (filling the deposit cap)
// with pushToDrawDownSink: true so the pool draws down MOET debt.
// Returns the user account. The position ID is always 0.
access(all)
fun setupPositionWithDebt(): Test.TestAccount {
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 1000.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: true
    )
    return user
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 1: Liquidation is blocked when a queued deposit would restore health ≥ 1.0
//
// With: 1000 FLOW @ $0.70, cf=0.8 → effectiveCollateral = 560
//       MOET debt ≈ 615.38 (drawn at initial price 1.0, targetHealth 1.3)
//       Credited health = 560 / 615.38 ≈ 0.91  (< 1.0 → normally liquidatable)
//
// Queuing 200 FLOW @ $0.70, cf=0.8 adds 112 to effectiveCollateral:
//       Queued health = 672 / 615.38 ≈ 1.09  (≥ 1.0 → not liquidatable)
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_liquidation_blocked_by_queued_deposit() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()

    // Drop FLOW price so credited health < 1.0.
    let crashedPrice: UFix64 = 0.7
    setMockOraclePrice(
        signer: Test.getAccount(0x0000000000000007),
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: crashedPrice
    )
    setMockDexPriceForPair(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        outVaultIdentifier: MOET_TOKEN_IDENTIFIER,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: crashedPrice
    )

    // Confirm credited health is below 1.0.
    let creditedHealth = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(creditedHealth < 1.0, message: "Expected credited health < 1.0 after price drop, got \(creditedHealth)")

    // Deposit 200 FLOW into the queue (deposit cap is exhausted, so it cannot enter the reserve).
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 200.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // Confirm the deposit is queued, not credited.
    let queued = getQueuedDeposits(pid: pid, beFailed: false)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!
    Test.assert(queued[flowType] != nil, message: "Expected 200 FLOW to be in the queue")

    // The position should now NOT be liquidatable because the queued deposit
    // brings queued health above 1.0.
    let liquidatable = getIsLiquidatable(pid: pid)
    Test.assert(!liquidatable, message: "Position should not be liquidatable when queued deposit rescues health")

    // A manual liquidation attempt should be rejected.
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)
    let liqRes = manualLiquidation(
        signer: liquidator,
        pid: pid,
        debtVaultIdentifier: Type<@MOET.Vault>().identifier,
        seizeVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        seizeAmount: 10.0,
        repayAmount: 7.0
    )
    Test.expect(liqRes, Test.beFailed())
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 2: Liquidation is still permitted when the queued deposit is insufficient
//         to restore health ≥ 1.0.
//
// Same setup as Test 1, but only 50 FLOW is queued:
//       Queued contribution = 50 × 0.7 × 0.8 = 28
//       Queued health = (560 + 28) / 615.38 ≈ 0.96  (< 1.0 → still liquidatable)
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_liquidation_allowed_when_queued_deposit_insufficient() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()

    let crashedPrice: UFix64 = 0.7
    setMockOraclePrice(
        signer: Test.getAccount(0x0000000000000007),
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: crashedPrice
    )
    setMockDexPriceForPair(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        outVaultIdentifier: MOET_TOKEN_IDENTIFIER,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: crashedPrice
    )

    // Queue only 50 FLOW — not enough to rescue the position.
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // Even with the queued deposit, queued health is < 1.0.
    let liquidatable = getIsLiquidatable(pid: pid)
    Test.assert(liquidatable, message: "Position should still be liquidatable when queued deposit is insufficient")
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 3: Rebalancing is skipped when queued deposits bring health within bounds.
//
// With: 1000 FLOW @ $0.80, cf=0.8 → effectiveCollateral = 640
//       MOET debt ≈ 615.38
//       Credited health = 640 / 615.38 ≈ 1.04  (< MIN_HEALTH = 1.1 → would trigger topUp)
//
// Queuing 100 FLOW @ $0.80, cf=0.8 adds 64 to effectiveCollateral:
//       Queued health = 704 / 615.38 ≈ 1.14  (within [1.1, 1.5] → no rebalance needed)
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_rebalance_skipped_when_queued_deposit_within_health_bounds() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()
    let userMoetBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    // Drop FLOW price so credited health falls below MIN_HEALTH (1.1) but not below 1.0.
    setMockOraclePrice(
        signer: PROTOCOL_ACCOUNT,
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: 0.8
    )

    let creditedHealth = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(creditedHealth < UFix128(MIN_HEALTH), message: "Expected credited health below MIN_HEALTH, got \(creditedHealth)")
    Test.assert(creditedHealth >= 1.0, message: "Credited health should still be above 1.0 (non-liquidatable), got \(creditedHealth)")

    // Queue 100 FLOW — sufficient to push queued health into [MIN_HEALTH, MAX_HEALTH].
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // With force=false the rebalancer should see queued health within bounds and do nothing.
    rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: pid, force: false, beFailed: false)

    // The user's MOET vault should be unchanged — no topUp was pulled.
    let userMoetAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(
        equalWithinVariance(userMoetBefore, userMoetAfter, DEFAULT_UFIX_VARIANCE),
        message: "No MOET should have been pulled from the user during rebalance (before: \(userMoetBefore), after: \(userMoetAfter))"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 4: The topUp amount is reduced to account for a queued deposit, preventing
//         over-rebalancing that would require a subsequent drawdown.
//
// With: 1000 FLOW @ $0.60, cf=0.8 → effectiveCollateral = 480
//       MOET debt ≈ 615.38
//       Credited health ≈ 0.78  (badly unhealthy — topUp required regardless)
//
// Queuing 200 FLOW @ $0.60, cf=0.8 adds 96 to effectiveCollateral:
//       Queued health ≈ 0.94  (still below MIN_HEALTH, so rebalance fires)
//
// Ideal topUp based on Queued balance sheet:
//       debt_after = 576 / 1.3 ≈ 443.08  →  topUp ≈ 172.30 MOET
//
// If instead the topUp were based on Credited health only:
//       debt_after = 480 / 1.3 ≈ 369.23  →  topUp ≈ 246.15 MOET
//       After queued deposit processes: health ≈ 1.56  (above MAX_HEALTH = 1.5 — needs drawdown!)
//
// We verify the new behaviour: MOET debt after rebalance is ≈ 443, not ≈ 369.
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_rebalance_topup_reduced_by_queued_deposit() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()

    // Drop FLOW price sharply so credited health is well below 1.0.
    setMockOraclePrice(
        signer: PROTOCOL_ACCOUNT,
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: 0.6
    )

    // Queue 200 FLOW. Even with it the queued health is below MIN_HEALTH,
    // so a rebalance will still be triggered — but the topUp should be sized
    // to reach targetHealth *including* the queued deposit's contribution.
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 200.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    let userMoetBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: pid, force: true, beFailed: false)
    let userMoetAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    let topUpAmount = userMoetBefore - userMoetAfter

    // New behaviour: topUp ≈ 172 MOET (accounts for 200 queued FLOW).
    // Old behaviour: topUp ≈ 246 MOET (ignores queued deposit).
    // We verify the topUp is substantially less than the old value to confirm
    // the queued deposit was taken into account.
    let oldBehaviourTopUp: UFix64 = 246.0
    let newBehaviourTopUp: UFix64 = 172.0
    let tolerance: UFix64 = 10.0

    Test.assert(
        equalWithinVariance(newBehaviourTopUp, topUpAmount, tolerance),
        message: "TopUp (\(topUpAmount)) should be close to \(newBehaviourTopUp) (accounting for queued deposit), not close to old value \(oldBehaviourTopUp)"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 5: Withdrawal from the deposit queue is permitted when credited health < minHealth
//         but queued health >= minHealth, and the withdrawal would not push queued health below minHealth.
//
// With: 1000 FLOW @ $0.75, cf=0.8 → reserve effectiveCollateral = 600
//       MOET debt ≈ 615.38
//       Credited health ≈ 0.975  (< 1.0 — below liquidation threshold)
//
// Queue 200 FLOW → queued health = (1000+200)*0.75*0.8 / 615.38 ≈ 1.17
//
// Withdraw 50 FLOW from the queue (the reserve is not touched):
//       Queued health after = (1000+150)*0.75*0.8 / 615.38 ≈ 1.12 >= minHealth(1.1) ✓
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_withdrawal_from_queue_permitted_when_reserve_health_below_min() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()

    // Drop FLOW price so that credited health falls below 1.0.
    setMockOraclePrice(
        signer: PROTOCOL_ACCOUNT,
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: 0.75
    )

    // Confirm credited health < 1.0.
    let creditedHealth = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(creditedHealth < 1.0, message: "Expected credited health < 1.0, got \(creditedHealth)")

    // Queue 200 FLOW — brings queued health to ≈ 1.17, well above minHealth(1.1).
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 200.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    let userFlowBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

    // Withdraw 50 FLOW — entirely from the queue (reserveWithdrawAmount = 0).
    // Queued health after ≈ 1.12 >= minHealth, so this should succeed.
    withdrawFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 50.0,
        pullFromTopUpSource: false
    )

    let userFlowAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert(
        equalWithinVariance(userFlowBefore + 50.0, userFlowAfter, DEFAULT_UFIX_VARIANCE),
        message: "User should have received 50 FLOW from the queue"
    )

    // Remaining queue should be 150.
    let queued = getQueuedDeposits(pid: pid, beFailed: false)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!
    Test.assert(
        equalWithinVariance(150.0, queued[flowType]!, DEFAULT_UFIX_VARIANCE),
        message: "Queue should hold 150 FLOW after withdrawing 50"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 6: Cross-type borrow against queued collateral is blocked.
//
// A queued FLOW deposit should not increase borrowing capacity for MOET.
// Only reserve FLOW should govern how much MOET can be withdrawn.
//
// With: 1000 FLOW reserve @ $1.0, cf=0.8, bf=1.0
//       MOET debt ≈ 615.38 (drawn at position creation, targetHealth=1.3)
//       Credited health = 1000*1.0*0.8 / 615.38 ≈ 1.3 (at target)
//       availableBalance(MOET) ≈ 0 (already at target health)
//
// Queue 500 FLOW (deposit cap exhausted, goes to queue).
//       A cross-type borrow would incorrectly increase MOET borrowing capacity.
//       The fix: queued FLOW provides no additional MOET borrow capacity.
//       Attempting to withdraw any additional MOET beyond the reserve allowance must fail.
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_queued_collateral_does_not_enable_cross_type_borrow() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()

    // Queue 500 FLOW (capacity is exhausted so it goes into the queue, not the reserve).
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 500.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    let queued = getQueuedDeposits(pid: pid, beFailed: false)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!
    Test.assert(queued[flowType] != nil, message: "Expected 500 FLOW to be queued")

    // Position is at targetHealth (1.3) with reserve FLOW only. No MOET should be available.
    // A cross-type borrow would try to use queued FLOW to support additional MOET withdrawal.
    // This must fail.
    let res = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [pid, MOET_TOKEN_IDENTIFIER, 100.0, false],
        user
    )
    Test.expect(res, Test.beFailed())
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 7: Withdrawal is rejected when it would drop queued health below 1.0,
//         even if part of it comes from the queue.
//
// With: 1000 FLOW @ $0.75, cf=0.8 → reserve effectiveCollateral = 600
//       MOET debt ≈ 615.38, credited health ≈ 0.975
// Queue 100 FLOW → queued health = 1100*0.75*0.8/615.38 ≈ 1.07
//
// Withdraw 200 FLOW (100 from queue, 100 from reserve):
//       Effective credit after = (1000-100) + (100-100) = 900
//       effectiveCollateral = 900*0.75*0.8 = 540 < 615.38 → health ≈ 0.88 < 1.0 → rejected
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_withdrawal_rejected_when_effective_health_would_drop_below_one() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()

    setMockOraclePrice(
        signer: PROTOCOL_ACCOUNT,
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: 0.75
    )

    // Queue 100 FLOW.
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // Attempt to withdraw 200 FLOW (drains queue and takes 100 from reserve).
    // Effective health after ≈ 0.88 < 1.0 — should be rejected.
    let res = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [pid, FLOW_TOKEN_IDENTIFIER, 200.0, false],
        user
    )
    Test.expect(res, Test.beFailed())
}
