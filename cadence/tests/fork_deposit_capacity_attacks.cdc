#test_fork(network: "mainnet-fork", height: 142528994)

import Test
import BlockchainHelpers

import "FlowToken"
import "FungibleToken"
import "MOET"
import "FlowALPEvents"

import "test_helpers.cdc"

access(all) let MAINNET_PROTOCOL_ACCOUNT = Test.getAccount(MAINNET_PROTOCOL_ACCOUNT_ADDRESS)

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

    createAndStorePool(signer: MAINNET_PROTOCOL_ACCOUNT, defaultTokenIdentifier: MAINNET_MOET_TOKEN_ID, beFailed: false)

    // Oracle prices set before snapshot so they persist across all tests after safeReset.
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_MOET_TOKEN_ID, price: 1.0)

    // Snapshot before token configuration so each test configures its own capacity
    // parameters fresh after safeReset (pattern from queued_deposits_integration_test.cdc).
    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Griefing: 1000 minimum-amount positions exhaust pool capacity
//
// An attacker creates many positions each depositing exactly the protocol
// minimum (1 FLOW), collectively consuming all available capacity. A
// legitimate user who arrives afterwards finds capacity exhausted: their
// deposit is fully queued and cannot be used as collateral.
// 
// =============================================================================
access(all)
fun testGriefingDepositCapacity() {
    safeReset()

    // minimumTokenBalancePerPosition = 1.0 FLOW enforces the floor each position
    // must hold. DepositCapacityCap = 10.0 so 10 attackers at minimum balance exhaust it.
    // DepositRate must be strictly positive; use the minimum valid value so
    // regeneration is negligible during test execution (rounds to 0.0 in UFix64).
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 0.00000001,
        depositCapacityCap: 10.0
    )
    setMinimumTokenBalancePerPosition(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        minimum: 1.0
    )
    // fraction=1.0 so a single tx can consume all remaining capacity at once.
    setDepositLimitFraction(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        fraction: 1.0
    )

    // 10 attackers each open a position with exactly the 1-FLOW minimum,
    // exhausting the 10-token capacity.
    var i = 0
    while i < 10 {
        let attacker = Test.createAccount()
        transferFlowTokens(to: attacker, amount: 1.0)
        createPosition(
            admin: MAINNET_PROTOCOL_ACCOUNT,
            signer: attacker,
            amount: 1.0,
            vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
            pushToDrawDownSink: false
        )
        i = i + 1
    }

    // Legitimate user arrives after griefing — user's 5 FLOW deposit is fully
    // queued because no capacity remains.
    let legitimateUser = Test.createAccount()
    transferFlowTokens(to: legitimateUser, amount: 5.0)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: legitimateUser,
        amount: 5.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let legitimatePid = getLastPositionId()

    let flowType = CompositeType(MAINNET_FLOW_TOKEN_ID)!

    // The legitimate user's FLOW is queued, not credited — it cannot be used as collateral.
    let queued = getQueuedDeposits(pid: legitimatePid, beFailed: false)
    Test.assertEqual(1, queued.length)
    Test.assertEqual(5.0, queued[flowType]!)

    let details = getPositionDetails(pid: legitimatePid, beFailed: false)
    let credited = getCreditBalanceForType(details: details, vaultType: flowType)
    Test.assertEqual(0.0, credited)
}

// =============================================================================
// Front-running: attacker consumes capacity ahead of a legitimate depositor
//
// The attacker deposits first and monopolises the full 100-token capacity.
// The legitimate user's deposit — prepared concurrently but arriving later —
// is fully queued and yields no immediate collateral credit.
// =============================================================================
access(all)
fun testFrontRunDepositCapacity() {
    safeReset()

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 0.00000001,
        depositCapacityCap: 100.0
    )
    setDepositLimitFraction(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        fraction: 1.0
    )

    // Attacker frontruns by depositing 100 FLOW, consuming all available capacity.
    let attacker = Test.createAccount()
    transferFlowTokens(to: attacker, amount: 100.0)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: attacker,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let attackerPid = getLastPositionId()

    // All 100 FLOW credited to the attacker immediately.
    let attackerDetails = getPositionDetails(pid: attackerPid, beFailed: false)
    let attackerCredit = getCreditBalanceForType(
        details: attackerDetails,
        vaultType: CompositeType(MAINNET_FLOW_TOKEN_ID)!
    )
    Test.assertEqual(100.0, attackerCredit)

    // Victim's 50 FLOW deposit lands after capacity is exhausted — all queued, no collateral.
    let victim = Test.createAccount()
    transferFlowTokens(to: victim, amount: 50.0)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: victim,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let victimPid = getLastPositionId()

    let flowType = CompositeType(MAINNET_FLOW_TOKEN_ID)!
    let victimQueued = getQueuedDeposits(pid: victimPid, beFailed: false)
    Test.assert(victimQueued[flowType] != nil, message: "Victim's FLOW should be queued after attacker consumed capacity")
    Test.assertEqual(50.0, victimQueued[flowType]!)

    let victimDetails = getPositionDetails(pid: victimPid, beFailed: false)
    let victimCredit = getCreditBalanceForType(details: victimDetails, vaultType: flowType)
    Test.assertEqual(0.0, victimCredit)
}

// =============================================================================
// Sybil: multiple accounts bypass the per-position deposit limit
//
// The protocol enforces a per-position deposit limit cap of depositLimitFraction ×
// depositCapacityCap. A single honest user is capped at 100 FLOW per position
// (5% of 2000); additional deposits are queued. However, the limit is per-position,
// not per-entity: a Sybil attacker creates two accounts and deposits 100 FLOW
// through each, collectively exceeding the per-position cap.
// =============================================================================
access(all)
fun testSybilPerUserLimitBypass() {
    safeReset()

    // Large cap so the per-tx deposit limit (capacity × fraction) stays near 100 FLOW
    // for all deposits and getUserDepositLimitCap (= 0.05 × 2000 = 100) is the binding limit.
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 0.00000001,
        depositCapacityCap: 2000.0
    )
    // Keep default fraction = 0.05 → getUserDepositLimitCap = 0.05 × 2000 = 100 FLOW per position.
    let perPositionCap = 100.0

    // Honest user: deposits exactly at the per-position cap.
    let honestUser = Test.createAccount()
    transferFlowTokens(to: honestUser, amount: perPositionCap + 50.0)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: honestUser,
        amount: perPositionCap,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let honestPid = getLastPositionId()
    let honestDetails = getPositionDetails(pid: honestPid, beFailed: false)
    let honestCredit = getCreditBalanceForType(
        details: honestDetails,
        vaultType: CompositeType(MAINNET_FLOW_TOKEN_ID)!
    )
    Test.assertEqual(perPositionCap, honestCredit)

    // Honest user tries to exceed the per-position cap: additional 50 FLOW is queued.
    depositToPosition(
        signer: honestUser,
        positionID: honestPid,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let flowType = CompositeType(MAINNET_FLOW_TOKEN_ID)!
    let honestQueued = getQueuedDeposits(pid: honestPid, beFailed: false)
    Test.assert(honestQueued[flowType] != nil, message: "Honest user's extra deposit should be queued at per-position cap")
    Test.assertEqual(50.0, honestQueued[flowType]!)

    // Sybil attacker: two separate accounts each deposit up to the per-position cap.
    // Each has an independent position with its own limit — no entity-level check exists.
    var sybilTotalCredit = 0.0

    let sybilAccount1 = Test.createAccount()
    transferFlowTokens(to: sybilAccount1, amount: perPositionCap)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: sybilAccount1,
        amount: perPositionCap,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let sybilPid1 = getLastPositionId()
    let sybilDetails1 = getPositionDetails(pid: sybilPid1, beFailed: false)
    let sybilCredit1 = getCreditBalanceForType(details: sybilDetails1, vaultType: flowType)
    Test.assert(sybilCredit1 > 0.0, message: "Sybil account 1 should have FLOW credited")
    sybilTotalCredit = sybilTotalCredit + sybilCredit1

    let sybilAccount2 = Test.createAccount()
    transferFlowTokens(to: sybilAccount2, amount: perPositionCap)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: sybilAccount2,
        amount: perPositionCap,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let sybilPid2 = getLastPositionId()
    let sybilDetails2 = getPositionDetails(pid: sybilPid2, beFailed: false)
    let sybilCredit2 = getCreditBalanceForType(details: sybilDetails2, vaultType: flowType)
    Test.assert(sybilCredit2 > 0.0, message: "Sybil account 2 should have FLOW credited")
    sybilTotalCredit = sybilTotalCredit + sybilCredit2

    // Each Sybil account has an independent per-position limit — together they exceed
    // the cap that constrains a single honest account.
    // Note: sybilTotalCredit < 2×perPositionCap because the per-tx limit
    // (depositCapacity × fraction) erodes with each deposit: after the honest user
    // consumes 100 FLOW the remaining capacity is 1900, giving sybil1 a per-tx limit
    // of 95 (not 100), and sybil2 a limit of ~90.25. The combined credit still exceeds
    // the per-position cap, proving the bypass.
    Test.assert(
        sybilTotalCredit > perPositionCap,
        message: "Sybil total credit should exceed the single-account per-position cap"
    )
}

// =============================================================================
// Capacity regeneration monopolization
//
// An attacker monitors regeneration and immediately re-deposits whenever
// capacity becomes available, accumulating far more collateral than the
// 100-token cap would suggest is possible.
//
// Setup: cap=100, depositRate=100/hour (fully regenerates every hour).
// Phase 1: Attacker1 deposits 100 FLOW, exhausting the initial capacity.
// Phase 2: One hour elapses (Test.moveTime by 3600s).
// Phase 3: Attacker2 deposits immediately — pool regenerates 100 FLOW on
//          this interaction and the attacker captures it all.
//
// Result: the attacker family collectively deposits 200 FLOW from a pool
// that only supports 100 tokens of capacity at a time. Any legitimate user
// who waited for regeneration would find capacity already consumed again.
//
// Note: Test.moveTime persists across all subsequent blocks in fork mode, so
// a legit-user-queued assertion would be unreliable (the legit user would
// also benefit from another regeneration cycle). The attack is instead proven
// by the 200-FLOW total: two full regeneration cycles captured back-to-back.
// =============================================================================
access(all)
fun testCapacityRegenerationMonopolization() {
    safeReset()

    // 100-token cap; depositRate=100/hour means capacity fully regenerates in 1 hour.
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 100.0,
        depositCapacityCap: 100.0
    )
    setDepositLimitFraction(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        fraction: 1.0
    )

    // Phase 1: attacker1 exhausts the full initial capacity immediately.
    let attacker1 = Test.createAccount()
    transferFlowTokens(to: attacker1, amount: 100.0)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: attacker1,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let attacker1Pid = getLastPositionId()

    let attacker1Details = getPositionDetails(pid: attacker1Pid, beFailed: false)
    let attacker1Credit = getCreditBalanceForType(
        details: attacker1Details,
        vaultType: CompositeType(MAINNET_FLOW_TOKEN_ID)!
    )
    // Capacity was 100 at setup; attacker1 consumed it all.
    Test.assertEqual(100.0, attacker1Credit)

    // Phase 2: an early depositor arrives before the clock advances — capacity is
    // exhausted so the full deposit is queued.
    let earlyDepositor = Test.createAccount()
    transferFlowTokens(to: earlyDepositor, amount: 100.0)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: earlyDepositor,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let earlyDepositorPid = getLastPositionId()
    let queued = getQueuedDeposits(pid: earlyDepositorPid, beFailed: false)
    Test.assertEqual(1, queued.length)

    // Phase 3: advance the clock by one hour so the pool will regenerate
    // 100 × (3600/3600) = 100 FLOW on the next interaction.
    Test.moveTime(by: 3600.0)

    // Phase 4: attacker2 deposits immediately after the time advance.
    // The pool's state-update runs first (dt=3600s → regen=100), then the
    // deposit consumes the newly available capacity in the same transaction.
    let attacker2 = Test.createAccount()
    transferFlowTokens(to: attacker2, amount: 100.0)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: attacker2,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let attacker2Pid = getLastPositionId()

    let attacker2Details = getPositionDetails(pid: attacker2Pid, beFailed: false)
    let attacker2Credit = getCreditBalanceForType(
        details: attacker2Details,
        vaultType: CompositeType(MAINNET_FLOW_TOKEN_ID)!
    )
    // attacker2 captured the full regenerated capacity.
    Test.assertEqual(100.0, attacker2Credit)

    // The attacker family collectively deposited 200 FLOW across two regeneration
    // cycles from a pool whose cap is only 100. Any legitimate user who monitored
    // regeneration and tried to deposit would find capacity consumed again.
    let totalAttackerCredit = attacker1Credit + attacker2Credit
    Test.assertEqual(200.0, totalAttackerCredit)
}

// =============================================================================
// Queued deposit exploitation: queued funds yield no collateral credit
//
// The full spec attack involves a user cancelling queued deposits after
// manipulating pool state, creating a potential race condition. This test
// covers the prerequisite invariant that is the root of that exploit:
// queued deposits are NOT counted as collateral, so a user holding queued
// funds has less borrowing power than they might expect.
//
// Setup: cap=50, fraction=1.0 → per-tx limit = capacity = 50.
// User deposits 100 FLOW: 50 credited, 50 queued.
// Effective collateral = 50 FLOW × 1.0 MOET/FLOW × CF(0.8) = 40 MOET.
//
// Borrow attempt 1: 40 MOET → health = 40/40 = 1.00 < minHealth(1.1) → FAILS.
//   (If queued 50 FLOW were counted: effective = 80 MOET, health = 80/40 = 2.0 — would pass.)
// Borrow attempt 2: 30 MOET → health = 40/30 = 1.33 ≥ 1.1 → SUCCEEDS.
// =============================================================================
access(all)
fun testQueuedDepositNotCreditedAsCollateral() {
    safeReset()

    // 50-token cap; fraction=1.0 so the first 50 FLOW of any deposit is accepted
    // and anything beyond is queued.
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 0.00000001,
        depositCapacityCap: 50.0
    )
    setDepositLimitFraction(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        fraction: 1.0
    )

    // MOET liquidity provider — deposits 1000 MOET so the pool can fulfil MOET borrows.
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 1000.0, beFailed: false)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: moetLp,
        amount: 1000.0,
        vaultStoragePath: MOET.VaultStoragePath,
        pushToDrawDownSink: false
    )

    // User deposits 100 FLOW: first 50 credited (capacity 50→0), remaining 50 queued.
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 100.0)
    createPosition(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: user,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let pid = getLastPositionId()

    // Verify the deposit split: 50 credited, 50 queued.
    let flowType = CompositeType(MAINNET_FLOW_TOKEN_ID)!
    let queued = getQueuedDeposits(pid: pid, beFailed: false)
    Test.assert(queued[flowType] != nil, message: "Expected queued FLOW after deposit exceeds per-tx limit")
    Test.assert(equalWithinVariance(50.0, queued[flowType]!, DEFAULT_UFIX_VARIANCE), message: "Expected 50 FLOW queued")

    let details = getPositionDetails(pid: pid, beFailed: false)
    let credited = getCreditBalanceForType(details: details, vaultType: flowType)
    Test.assert(equalWithinVariance(50.0, credited, DEFAULT_UFIX_VARIANCE), message: "Expected 50 FLOW credited")

    // Borrow 40 MOET: health = (50 × 0.8) / 40 = 40/40 = 1.00 < minHealth(1.1) → FAILS.
    // If queued funds were counted (100 FLOW), effective collateral = 80 and health = 2.0 — would pass.
    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultStoragePath: MOET.VaultStoragePath,
        amount: 40.0,
        beFailed: true
    )

    // Borrow 30 MOET: health = 40/30 = 1.33 ≥ 1.1 → SUCCEEDS using only the 50 credited FLOW.
    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultStoragePath: MOET.VaultStoragePath,
        amount: 30.0,
        beFailed: false
    )

    // Confirm only the successful 30 MOET borrow is recorded as debt.
    let detailsAfterBorrow = getPositionDetails(pid: pid, beFailed: false)
    let moetDebt = getDebitBalanceForType(
        details: detailsAfterBorrow,
        vaultType: Type<@MOET.Vault>()
    )
    Test.assertEqual(30.0, moetDebt)
}
