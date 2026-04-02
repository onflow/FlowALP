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
//       Reserve health = 560 / 615.38 ≈ 0.91  (< 1.0 → normally liquidatable)
//
// Queuing 200 FLOW @ $0.70, cf=0.8 adds 112 to effectiveCollateral:
//       Effective health = 672 / 615.38 ≈ 1.09  (≥ 1.0 → not liquidatable)
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_liquidation_blocked_by_queued_deposit() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()

    // Drop FLOW price so reserve health < 1.0.
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

    // Confirm reserve health is below 1.0.
    let reserveHealth = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(reserveHealth < 1.0, message: "Expected reserve health < 1.0 after price drop, got \(reserveHealth)")

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
    // brings effective health above 1.0.
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
//       Effective health = (560 + 28) / 615.38 ≈ 0.96  (< 1.0 → still liquidatable)
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

    // Even with the queued deposit, effective health is < 1.0.
    let liquidatable = getIsLiquidatable(pid: pid)
    Test.assert(liquidatable, message: "Position should still be liquidatable when queued deposit is insufficient")
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 3: Rebalancing is skipped when queued deposits bring health within bounds.
//
// With: 1000 FLOW @ $0.80, cf=0.8 → effectiveCollateral = 640
//       MOET debt ≈ 615.38
//       Reserve health = 640 / 615.38 ≈ 1.04  (< MIN_HEALTH = 1.1 → would trigger topUp)
//
// Queuing 100 FLOW @ $0.80, cf=0.8 adds 64 to effectiveCollateral:
//       Effective health = 704 / 615.38 ≈ 1.14  (within [1.1, 1.5] → no rebalance needed)
// ─────────────────────────────────────────────────────────────────────────────
access(all)
fun test_rebalance_skipped_when_queued_deposit_within_health_bounds() {
    safeReset()
    let pid: UInt64 = 0

    let user = setupPositionWithDebt()
    let userMoetBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    // Drop FLOW price so reserve health falls below MIN_HEALTH (1.1) but not below 1.0.
    setMockOraclePrice(
        signer: PROTOCOL_ACCOUNT,
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: 0.8
    )

    let reserveHealth = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(reserveHealth < UFix128(MIN_HEALTH), message: "Expected reserve health below MIN_HEALTH, got \(reserveHealth)")
    Test.assert(reserveHealth >= 1.0, message: "Reserve health should still be above 1.0 (non-liquidatable), got \(reserveHealth)")

    // Queue 100 FLOW — sufficient to push effective health into [MIN_HEALTH, MAX_HEALTH].
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // With force=false the rebalancer should see effective health within bounds and do nothing.
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
//       Reserve health ≈ 0.78  (badly unhealthy — topUp required regardless)
//
// Queuing 200 FLOW @ $0.60, cf=0.8 adds 96 to effectiveCollateral:
//       Effective health ≈ 0.94  (still below MIN_HEALTH, so rebalance fires)
//
// Ideal topUp based on EFFECTIVE balance sheet:
//       debt_after = 576 / 1.3 ≈ 443.08  →  topUp ≈ 172.30 MOET
//
// If instead the topUp were based on RESERVE health only (old behaviour):
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

    // Drop FLOW price sharply so reserve health is well below 1.0.
    setMockOraclePrice(
        signer: PROTOCOL_ACCOUNT,
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: 0.6
    )

    // Queue 200 FLOW. Even with it the effective health is below MIN_HEALTH,
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
