import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

access(all) let MOET_VAULT_STORAGE_PATH = /storage/moetTokenVault_0x0000000000000007

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
}

/// Creates a user, opens a position with auto-borrow at targetHealth. Position ID is 0.
access(all)
fun setupUserWithPosition(_ flowAmount: UFix64): Test.TestAccount {
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: flowAmount)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: flowAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)
    return user
}

/// Creates a user, opens a position WITHOUT source/sink.
/// If borrow > 0, an LP position is created first to provide MOET liquidity.
/// The bare position ID is 0 when borrow == 0, or 1 when borrow > 0 (LP is 0).
access(all)
fun setupUserWithBarePosition(_ flowAmount: UFix64, borrow: UFix64): Test.TestAccount {
    // If borrowing MOET, we need liquidity in the pool first.
    if borrow > 0.0 {
        let lp = Test.createAccount()
        setupMoetVault(lp, beFailed: false)
        mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: borrow * 2.0, beFailed: false)
        mintFlow(to: lp, amount: 10.0) // small FLOW deposit so LP can create a position
        createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 10.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
        depositToPosition(signer: lp, positionID: 0, amount: borrow * 2.0, vaultStoragePath: MOET_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    }

    let user = Test.createAccount()
    mintFlow(to: user, amount: flowAmount)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)
    let res = _executeTransaction(
        "./transactions/position-manager/create_position_no_connectors.cdc",
        [flowAmount, FLOW_VAULT_STORAGE_PATH],
        user
    )
    Test.expect(res, Test.beSucceeded())

    if borrow > 0.0 {
        setupMoetVault(user, beFailed: false)
        let pid = UInt64(1) // bare position is after LP position
        borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, vaultStoragePath: MOET_VAULT_STORAGE_PATH, amount: borrow, beFailed: false)
    }
    return user
}

// ============================================================
// withdrawAndPull tests
// ============================================================

/// Scenario 1: pull=false, health stays above minHealth → succeed.
access(all)
fun test_withdraw_noPull_aboveMinHealth_succeeds() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)

    withdrawFromPosition(signer: user, positionId: 0, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, receiverVaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 10.0, pullFromTopUpSource: false)

    Test.assert(getPositionHealth(pid: 0, beFailed: false) > INT_MIN_HEALTH)
}

/// Scenario 2: pull=false, health breaches minHealth → fail.
access(all)
fun test_withdraw_noPull_breachesMinHealth_fails() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)

    let res = _executeTransaction(
        "./transactions/flow-alp/epositionadmin/withdraw_from_position.cdc",
        [0 as UInt64, FLOW_TOKEN_IDENTIFIER, 900.0, false],
        user
    )
    Test.expect(res, Test.beFailed())
}

/// Scenario 3: pull=true, health stays above targetHealth → succeed, no pull.
access(all)
fun test_withdraw_pull_aboveTargetHealth_noPull() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)
    // Deposit extra FLOW without push to raise health above targetHealth
    mintFlow(to: user, amount: 100.0)
    depositToPosition(signer: user, positionID: 0, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let moetBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    // Small withdrawal keeps health above targetHealth — no pull should occur
    withdrawFromPosition(signer: user, positionId: 0, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, receiverVaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 10.0, pullFromTopUpSource: true)

    let moetAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(equalWithinVariance(moetBefore, moetAfter, DEFAULT_UFIX_VARIANCE),
        message: "No pull should occur. MOET before: ".concat(moetBefore.toString()).concat(", after: ").concat(moetAfter.toString()))
}

/// Scenario 4: pull=true, health between min and target, source has enough → restores targetHealth.
access(all)
fun test_withdraw_pull_belowTarget_sourceHasEnough_restoresTarget() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)

    withdrawFromPosition(signer: user, positionId: 0, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, receiverVaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 50.0, pullFromTopUpSource: true)

    Test.assert(equalWithinVariance(INT_TARGET_HEALTH, getPositionHealth(pid: 0, beFailed: false), DEFAULT_UFIX128_VARIANCE))
}

/// Scenario 5: pull=true, health between min and target, source has partial funds → best-effort.
access(all)
fun test_withdraw_pull_belowTarget_sourcePartial_bestEffort() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)

    // Drain most MOET from topUpSource, leaving only 5
    let receiver = Test.createAccount()
    setupMoetVault(receiver, beFailed: false)
    let userMoet = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    transferFungibleTokens(tokenIdentifier: MOET_TOKEN_IDENTIFIER, from: user, to: receiver, amount: userMoet - 5.0)

    withdrawFromPosition(signer: user, positionId: 0, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, receiverVaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 50.0, pullFromTopUpSource: true)

    let health = getPositionHealth(pid: 0, beFailed: false)
    Test.assert(health > INT_MIN_HEALTH, message: "Should be > minHealth but was ".concat(health.toString()))
    Test.assert(health < INT_TARGET_HEALTH, message: "Should be < targetHealth (best-effort) but was ".concat(health.toString()))
}

/// Scenario 6: pull=true, health between min and target, no source → succeed (above minHealth).
access(all)
fun test_withdraw_pull_belowTarget_noSource_succeeds() {
    safeReset()
    // Create position without source, borrow 615 MOET (health ~1.3)
    let user = setupUserWithBarePosition(1_000.0, borrow: 615.0)

    // Withdraw with pull=true. No source, but position stays above minHealth → should succeed.
    let res = _executeTransaction(
        "./transactions/flow-alp/epositionadmin/withdraw_from_position.cdc",
        [1 as UInt64, FLOW_TOKEN_IDENTIFIER, FLOW_VAULT_STORAGE_PATH, 50.0, true],
        user
    )
    Test.expect(res, Test.beSucceeded())

    Test.assert(getPositionHealth(pid: 1, beFailed: false) >= INT_MIN_HEALTH)
}

/// Scenario 7: pull=true, breaches minHealth, source restores → succeed at targetHealth.
access(all)
fun test_withdraw_pull_breachesMin_sourceRestores_succeeds() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)

    withdrawFromPosition(signer: user, positionId: 0, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, receiverVaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 200.0, pullFromTopUpSource: true)

    Test.assert(equalWithinVariance(INT_TARGET_HEALTH, getPositionHealth(pid: 0, beFailed: false), DEFAULT_UFIX128_VARIANCE))
}

/// Scenario 8: pull=true, breaches minHealth, source insufficient → fail.
access(all)
fun test_withdraw_pull_breachesMin_sourceInsufficient_fails() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)

    // Drain nearly all MOET
    let receiver = Test.createAccount()
    setupMoetVault(receiver, beFailed: false)
    let userMoet = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    transferFungibleTokens(tokenIdentifier: MOET_TOKEN_IDENTIFIER, from: user, to: receiver, amount: userMoet - 1.0)

    let res = _executeTransaction(
        "./transactions/flow-alp/epositionadmin/withdraw_from_position.cdc",
        [0 as UInt64, FLOW_TOKEN_IDENTIFIER, 900.0, true],
        user
    )
    Test.expect(res, Test.beFailed())
}

// ============================================================
// depositAndPush tests
// ============================================================

/// Scenario 9: push=false → succeed, no rebalance, health rises above target.
access(all)
fun test_deposit_noPush_noRebalance() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)
    mintFlow(to: user, amount: 100.0)

    depositToPosition(signer: user, positionID: 0, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    Test.assert(getPositionHealth(pid: 0, beFailed: false) > INT_TARGET_HEALTH)
}

/// Scenario 10: push=true, health still below targetHealth after deposit → succeed, nothing to push.
access(all)
fun test_deposit_push_belowTarget_succeeds() {
    safeReset()
    // Position without sink, heavily borrowed (health ~1.14). LP is pid 0, bare is pid 1.
    let user = setupUserWithBarePosition(1_000.0, borrow: 700.0)

    mintFlow(to: user, amount: 5.0)
    depositToPosition(signer: user, positionID: 1, amount: 5.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    Test.assert(getPositionHealth(pid: 1, beFailed: false) < INT_TARGET_HEALTH)
}

/// Scenario 11: push=true, health above targetHealth, sink has capacity → restores targetHealth.
access(all)
fun test_deposit_push_aboveTarget_restoresTarget() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)
    mintFlow(to: user, amount: 100.0)

    depositToPosition(signer: user, positionID: 0, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    Test.assert(equalWithinVariance(INT_TARGET_HEALTH, getPositionHealth(pid: 0, beFailed: false), DEFAULT_UFIX128_VARIANCE))
}

/// Scenario 12: push=true, health above targetHealth, sink limited → best-effort.
access(all)
fun test_deposit_push_aboveTarget_sinkLimited_bestEffort() {
    safeReset()
    let user = setupUserWithPosition(1_000.0)

    // Deposit a very large amount — pool reserves will not have enough MOET to fully rebalance.
    mintFlow(to: user, amount: 50_000.0)
    depositToPosition(signer: user, positionID: 0, amount: 50_000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    Test.assert(getPositionHealth(pid: 0, beFailed: false) > INT_TARGET_HEALTH)
}

/// Scenario 13: push=true, health above targetHealth, no sink → succeed (deposit always works).
access(all)
fun test_deposit_push_aboveTarget_noSink_succeeds() {
    safeReset()
    // Position without sink, no debt
    let user = setupUserWithBarePosition(1_000.0, borrow: 0.0)

    mintFlow(to: user, amount: 100.0)
    depositToPosition(signer: user, positionID: 0, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    Test.assert(getPositionHealth(pid: 0, beFailed: false) > INT_TARGET_HEALTH)
}
