import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

// =============================================================================
// Security Permission Tests
// =============================================================================
//
// This file validates the Actor Capability Matrix defined in:
//   docs/security-permission-matrix.md
//
// One section per entitlement. Each section uses the production actor for that
// entitlement and covers ALL matrix operations for that entitlement.
// Role accounts are configured in setup() with the exact access they would
// receive in production.
//
//   eParticipantUser         — Capability<auth(EParticipant) &Pool>
//                              Published via the FIXED publish_beta_cap.cdc.
//                              Cap stored at FlowALPv0.PoolCapStoragePath.
//
//   ePositionUser            — Capability<auth(EPosition) &Pool>
//                              EPosition-only capability; can perform pool-level position
//                              ops on any position by ID. No EParticipant.
//                              Cap stored at FlowALPv0.PoolCapStoragePath.
//
//   eParticipantPositionUser — Capability<auth(EParticipant, EPosition) &Pool> over-grant
//                              Current (unfixed) beta cap — grants EPosition unnecessarily.
//                              Cap stored at FlowALPv0.PoolCapStoragePath.
//
//   eRebalanceUser           — Capability<auth(ERebalance) &Pool>
//                              Narrowly-scoped cap for rebalancer contracts.
//                              Cap stored at FlowALPv0.PoolCapStoragePath.
//
//   ePositionAdminUser       — No Pool capability; has PositionManager in own storage.
//                              EPositionAdmin access is via storage ownership — cannot
//                              be delegated as a capability.
//
//   eGovernanceUser          — Capability<auth(EGovernance) &Pool>
//                              Granted by PROTOCOL_ACCOUNT via grant_egovernance_cap.cdc.
//                              Cap stored at FlowALPv0.PoolCapStoragePath.
//
//   PROTOCOL_ACCOUNT         — Pool owner; exercises EImplementation directly via storage borrow.
//
// Negative tests:
//   Cadence entitlements for Pool capabilities are enforced by the Cadence type checker.
//   Only borrowAuthorizedPosition has a runtime enforcement (it panics if the pid is not in
//   the signer's PositionManager), so testEPositionAdmin_BorrowUnauthorizedPosition_Fails tests that path.
// =============================================================================


// Position created for PROTOCOL_ACCOUNT in setup — used as target for EPosition tests.
access(all) var setupPid: UInt64 = 0
access(all) var ePositionAdminPid: UInt64 = 0

access(all) var snapshot: UInt64 = 0

// Role accounts
access(all) var eParticipantUser = Test.createAccount()
access(all) var ePositionUser = Test.createAccount()
access(all) var eParticipantPositionUser = Test.createAccount()
access(all) var eRebalanceUser = Test.createAccount()
access(all) var ePositionAdminUser = Test.createAccount()
access(all) var eGovernanceUser = Test.createAccount()

access(all)
fun safeReset() {
    if getCurrentBlockHeight() > snapshot {
        Test.reset(to: snapshot)
    }
}

/// Execute a 2-authorizer transaction (e.g. admin + grantee for capability setup).
access(all)
fun _execute2Signers(
    _ path: String,
    _ args: [AnyStruct],
    _ s1: Test.TestAccount,
    _ s2: Test.TestAccount
): Test.TransactionResult {
    let signers = s1.address == s2.address ? [s1] : [s1, s2]
    return Test.executeTransaction(Test.Transaction(
        code: Test.readFile(path),
        authorizers: [s1.address, s2.address],
        signers: signers,
        arguments: args
    ))
}

// -----------------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------------

access(all)
fun setup() {
    deployContracts()

    // Create pool with MOET as the default token, oracle price = $1
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: PROTOCOL_ACCOUNT.address, amount: 1_000.0, beFailed: false)

    // Verify pool invariants before setting up role accounts
    let exists = poolExists(address: PROTOCOL_ACCOUNT.address)
    Test.assert(exists)
    let reserveBal = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(0.0, reserveBal)

    // Create setupPid=0 owned by PROTOCOL_ACCOUNT.
    // Used as target in EPosition/ERebalance tests.
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: PROTOCOL_ACCOUNT,
        amount: 10.0,
        vaultStoragePath: MOET.VaultStoragePath,
        pushToDrawDownSink: false
    )

    setupPid = getLastPositionId()

    // ─────────────────────────────────────────────────────────────────────────
    // EParticipant user — EParticipant-ONLY capability (fixed beta cap)
    // ─────────────────────────────────────────────────────────────────────────
    setupMoetVault(eParticipantUser, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: eParticipantUser.address, amount: 100.0, beFailed: false)
    Test.expect(
        _execute2Signers(
            "../tests/transactions/flow-alp/setup/grant_eparticipant_cap.cdc",
            [],
            PROTOCOL_ACCOUNT,
            eParticipantUser
        ),
        Test.beSucceeded()
    )

    // ─────────────────────────────────────────────────────────────────────────
    // EPosition user — EPosition-ONLY capability (no EParticipant)
    // ─────────────────────────────────────────────────────────────────────────
    setupMoetVault(ePositionUser, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: ePositionUser.address, amount: 100.0, beFailed: false)
    Test.expect(
        _execute2Signers(
            "../tests/transactions/flow-alp/setup/grant_eposition_cap.cdc",
            [],
            PROTOCOL_ACCOUNT,
            ePositionUser
        ),
        Test.beSucceeded()
    )

    // ─────────────────────────────────────────────────────────────────────────
    // EParticipantPosition user — EParticipant+EPosition capability (current over-grant)
    // ─────────────────────────────────────────────────────────────────────────
    setupMoetVault(eParticipantPositionUser, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: eParticipantPositionUser.address, amount: 100.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, eParticipantPositionUser)

    // ─────────────────────────────────────────────────────────────────────────
    // ERebalance user — ERebalance-only capability (rebalancer simulation)
    // ─────────────────────────────────────────────────────────────────────────
    Test.expect(
        _execute2Signers(
            "../tests/transactions/flow-alp/setup/grant_erebalance_cap.cdc",
            [],
            PROTOCOL_ACCOUNT,
            eRebalanceUser
        ),
        Test.beSucceeded()
    )

    // ─────────────────────────────────────────────────────────────────────────
    // EPositionAdmin user — has PositionManager in own storage (pid=1)
    // EPositionAdmin access comes from storage ownership, not a delegated cap.
    // ─────────────────────────────────────────────────────────────────────────
    setupMoetVault(ePositionAdminUser, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: ePositionAdminUser.address, amount: 100.0, beFailed: false)
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: ePositionAdminUser,
        amount: 10.0,
        vaultStoragePath: MOET.VaultStoragePath,
        pushToDrawDownSink: false
    )
    ePositionAdminPid = getLastPositionId()

    // ─────────────────────────────────────────────────────────────────────────
    // EGovernance user — EGovernance capability delegated from PROTOCOL_ACCOUNT
    // ─────────────────────────────────────────────────────────────────────────
    Test.expect(
        _execute2Signers(
            "../tests/transactions/flow-alp/setup/grant_egovernance_cap.cdc",
            [],
            PROTOCOL_ACCOUNT,
            eGovernanceUser
        ),
        Test.beSucceeded()
    )

    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Publish / Claim flow — capability grant mechanism
// =============================================================================

/// publish → claim → create position round-trip using production beta transactions.
access(all)
fun testPublishClaimCap() {
    safeReset()
    
    let publishCapResult = _executeTransaction(
        "../transactions/flow-alp/beta/publish_beta_cap.cdc",
        [PROTOCOL_ACCOUNT.address],
        PROTOCOL_ACCOUNT
    )
    Test.expect(publishCapResult, Test.beSucceeded())

    let claimCapResult = _executeTransaction(
        "../transactions/flow-alp/beta/claim_and_save_beta_cap.cdc",
        [PROTOCOL_ACCOUNT.address],
        PROTOCOL_ACCOUNT
    )
    Test.expect(claimCapResult, Test.beSucceeded())

    let createPositionResult = _executeTransaction(
        "../tests/transactions/flow-alp/eparticipant/create_position_via_published_cap.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(createPositionResult, Test.beSucceeded())
}

// =============================================================================
// EParticipant — fixed beta capability (EParticipant only)
// =============================================================================
//
// Actor: eParticipantUser — Capability<auth(EParticipant) &Pool>
// Matrix rows: createPosition, depositToPosition

/// EParticipant cap allows createPosition and depositToPosition.
access(all)
fun testEParticipant_CreateAndDeposit() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eparticipant/create_and_deposit_via_cap.cdc",
        [],
        eParticipantUser
    )
    Test.expect(result, Test.beSucceeded())
}

// =============================================================================
// EParticipant+EPosition — over-grant (current beta cap via publish_beta_cap.cdc)
// =============================================================================
//
// Actor: eParticipantPositionUser — Capability<auth(EParticipant, EPosition) &Pool>
//        Issued by publish_beta_cap.cdc and stored at FlowALPv0.PoolCapStoragePath.
//        This is the CURRENT (unfixed) beta cap. EPosition is NOT needed for normal
//        user actions; its presence lets this actor perform pool-level position ops
//        on ANY position, including positions owned by other accounts.
//
// Matrix rows: createPosition (EParticipant), depositToPosition (EParticipant),
//              withdraw [OVERGRANT], withdrawAndPull [OVERGRANT], depositAndPush [OVERGRANT],
//              lockPosition [OVERGRANT], unlockPosition [OVERGRANT], rebalancePosition [OVERGRANT],
//              rebalance (Position) [OVERGRANT — same entry point as rebalancePosition]
//
// The [OVERGRANT] rows confirm the security issue: a normal beta user can operate on
// positions they do not own (setupPid is owned by PROTOCOL_ACCOUNT).

/// Over-granted beta cap still allows EParticipant operations (createPosition, depositToPosition).
access(all)
fun testEParticipantPosition_CreateAndDeposit() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eparticipant/create_and_deposit_via_cap.cdc",
        [],
        eParticipantPositionUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// Over-granted beta cap allows Pool.withdraw on ANY position — including
/// setupPid owned by PROTOCOL_ACCOUNT.
access(all)
fun testEParticipantPosition_WithdrawAnyPosition() {
    safeReset()

    let balanceBefore = getBalance(address: eParticipantPositionUser.address, vaultPublicPath: MOET.VaultPublicPath)!
    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/withdraw_any.cdc",
        [setupPid, 1.0],
        eParticipantPositionUser
    )
    Test.expect(result, Test.beSucceeded())
    let balanceAfter = getBalance(address: eParticipantPositionUser.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(balanceAfter, balanceBefore + 1.0)
}

/// Over-granted beta cap allows Pool.withdrawAndPull on ANY position — including
/// positions owned by other accounts.
access(all)
fun testEParticipantPosition_WithdrawAndPullAnyPosition() {
    safeReset()

    let balanceBefore = getBalance(address: eParticipantPositionUser.address, vaultPublicPath: MOET.VaultPublicPath)!
    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/withdraw_and_pull_any.cdc",
        [setupPid, 1.0],
        eParticipantPositionUser
    )
    Test.expect(result, Test.beSucceeded())
    let balanceAfter = getBalance(address: eParticipantPositionUser.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(balanceAfter, balanceBefore + 1.0)
}

/// Over-granted beta cap allows Pool.depositAndPush on ANY position — including
/// positions owned by other accounts.
access(all)
fun testEParticipantPosition_DepositAndPushAnyPosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/deposit_and_push_any.cdc",
        [setupPid, 1.0],
        eParticipantPositionUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// Over-granted beta cap allows Pool.lockPosition and Pool.unlockPosition on ANY position —
/// including positions owned by other accounts.
access(all)
fun testEParticipantPosition_LockUnlockAnyPosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/lock_any.cdc",
        [setupPid],
        eParticipantPositionUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// Over-granted beta cap allows Pool.rebalancePosition on any position.
access(all)
fun testEParticipantPosition_RebalancePosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/rebalance_position_via_cap.cdc",
        [setupPid, true],
        eParticipantPositionUser
    )
    Test.expect(result, Test.beSucceeded())
}

// =============================================================================
// EPosition — narrowly-scoped EPosition-only Pool capability
// =============================================================================
//
// Actor: ePositionUser — Capability<auth(EPosition) &Pool>
// Matrix rows: withdraw, withdrawAndPull, depositAndPush, lockPosition, unlockPosition,
//              rebalancePosition

/// EPosition cap allows Pool.withdraw on ANY position by ID — including
/// setupPid owned by PROTOCOL_ACCOUNT.
access(all)
fun testEPosition_WithdrawAnyPosition() {
    safeReset()

    let balanceBefore = getBalance(address: ePositionUser.address, vaultPublicPath: MOET.VaultPublicPath)!
    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/withdraw_any.cdc",
        [setupPid, 1.0],
        ePositionUser
    )
    Test.expect(result, Test.beSucceeded())
    let balanceAfter = getBalance(address: ePositionUser.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(balanceAfter, balanceBefore + 1.0)
}

/// EPosition cap allows Pool.withdrawAndPull on ANY position — including positions
/// owned by other accounts.
access(all)
fun testEPosition_WithdrawAndPullAnyPosition() {
    safeReset()

    let balanceBefore = getBalance(address: ePositionUser.address, vaultPublicPath: MOET.VaultPublicPath)!
    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/withdraw_and_pull_any.cdc",
        [setupPid, 1.0],
        ePositionUser
    )
    Test.expect(result, Test.beSucceeded())
    let balanceAfter = getBalance(address: ePositionUser.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(balanceAfter, balanceBefore + 1.0)
}

/// EPosition cap allows Pool.depositAndPush on ANY position — including positions
/// owned by other accounts.
access(all)
fun testEPosition_DepositAndPushAnyPosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/deposit_and_push_any.cdc",
        [setupPid, 1.0],
        ePositionUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EPosition cap allows Pool.lockPosition and Pool.unlockPosition on ANY position —
/// including positions owned by other accounts.
access(all)
fun testEPosition_LockUnlockAnyPosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/lock_any.cdc",
        [setupPid],
        ePositionUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EPosition cap allows Pool.rebalancePosition.
access(all)
fun testEPosition_RebalancePosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eposition/rebalance_position_via_cap.cdc",
        [setupPid, true],
        ePositionUser
    )
    Test.expect(result, Test.beSucceeded())
}

// =============================================================================
// ERebalance — narrowly-scoped rebalancer capability
// =============================================================================
//
// Actor: eRebalanceUser — Capability<auth(ERebalance) &Pool> @ PoolCapStoragePath
// Matrix rows: rebalancePosition, rebalance (Position)
//   Both tested via pool.rebalancePosition(); Position.rebalance() delegates to same call.
//   Contract fix: Position.pool changed to Capability<auth(EPosition | ERebalance) &Pool>
//   so the internal call chain works for ERebalance callers.

/// ERebalance cap allows Pool.rebalancePosition.
access(all)
fun testERebalance_RebalancePosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/erebalance/rebalance_position_via_cap.cdc",
        [setupPid, true],
        eRebalanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// Matrix row: rebalance (Position) — Position.rebalance() delegates to Pool.rebalancePosition()
/// internally, so both matrix rows share the same Pool-level entry point. There is no separate
/// transaction that calls Position.rebalance() directly; this test confirms the ERebalance
/// entitlement is sufficient for the rebalancePosition call that Position.rebalance() invokes.
/// (The contract fix changes Position.pool to Capability<auth(EPosition | ERebalance) &Pool>
/// so the internal call chain accepts ERebalance callers.)
access(all)
fun testERebalance_PositionRebalance() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/erebalance/rebalance_position_via_cap.cdc",
        [setupPid, true],
        eRebalanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

// =============================================================================
// EPositionAdmin — storage ownership of PositionManager (not a capability)
// =============================================================================
//
// Actor: ePositionAdminUser — has PositionManager in own storage (cannot be delegated).
// Matrix rows: setTargetHealth, setMinHealth, setMaxHealth, provideSink, provideSource,
//              addPosition (Manager), removePosition (Manager), borrowAuthorizedPosition
//
// Note: testEPositionAdmin_AddRemovePosition uses PROTOCOL_ACCOUNT because
// add_remove_position.cdc creates a fresh position via pool storage (EParticipant),
// which ePositionAdminUser does not hold. The EPositionAdmin entitlement is still
// tested via the PositionManager borrow inside the transaction.

/// EPositionAdmin allows Position.setTargetHealth (via PositionManager.borrowAuthorizedPosition).
access(all)
fun testEPositionAdmin_SetTargetHealth() {
    safeReset()

    let result = _executeTransaction(
        "../transactions/flow-alp/position/set_target_health.cdc",
        [ePositionAdminPid, TARGET_HEALTH],
        ePositionAdminUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EPositionAdmin allows Position.setMinHealth (via PositionManager.borrowAuthorizedPosition).
access(all)
fun testEPositionAdmin_SetMinHealth() {
    safeReset()

    let result = _executeTransaction(
        "../transactions/flow-alp/position/set_min_health.cdc",
        [ePositionAdminPid, MIN_HEALTH],
        ePositionAdminUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EPositionAdmin allows Position.setMaxHealth (via PositionManager.borrowAuthorizedPosition).
access(all)
fun testEPositionAdmin_SetMaxHealth() {
    safeReset()

    let result = _executeTransaction(
        "../transactions/flow-alp/position/set_max_health.cdc",
        [ePositionAdminPid, MAX_HEALTH],
        ePositionAdminUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EPositionAdmin allows Position.provideSink.
/// Sets a DummySink (accepts MOET) then clears it with nil.
access(all)
fun testEPositionAdmin_ProvideSink() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/epositionadmin/provide_sink.cdc",
        [ePositionAdminPid],
        ePositionAdminUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EPositionAdmin allows Position.provideSource.
/// Calls provideSource(nil) to clear any existing source — always valid.
access(all)
fun testEPositionAdmin_ProvideSource() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/epositionadmin/provide_source.cdc",
        [ePositionAdminPid],
        ePositionAdminUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EPositionAdmin allows PositionManager.addPosition and PositionManager.removePosition.
/// Creates a fresh position, adds it to the manager, removes it, and destroys it.
/// Uses PROTOCOL_ACCOUNT because the transaction needs pool storage access to create
/// the position (EParticipant) — which ePositionAdminUser does not hold.
access(all)
fun testEPositionAdmin_AddRemovePosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/epositionadmin/add_remove_position.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(result, Test.beSucceeded())
}

/// EPositionAdmin allows PositionManager.borrowAuthorizedPosition.
access(all)
fun testEPositionAdmin_BorrowAuthorizedPosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/epositionadmin/borrow_authorized.cdc",
        [ePositionAdminPid],
        ePositionAdminUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// Negative: borrowAuthorizedPosition panics when the requested pid is not in the signer's
/// PositionManager. setupPid is owned by PROTOCOL_ACCOUNT, not ePositionAdminUser.
/// This is the only runtime-enforced access denial in this file — all other entitlements
/// are enforced statically by the Cadence type checker at check time.
access(all)
fun testEPositionAdmin_BorrowUnauthorizedPosition_Fails() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/epositionadmin/borrow_authorized.cdc",
        [setupPid],
        ePositionAdminUser
    )
    Test.expect(result, Test.beFailed())
}

// =============================================================================
// EGovernance — capability-delegated governance access
// =============================================================================
//
// Actor: eGovernanceUser — Capability<auth(EGovernance) &Pool>
// Matrix rows: pausePool/unpausePool, addSupportedToken, setInterestCurve, setInsuranceRate,
//              setStabilityFeeRate, setLiquidationParams, setPauseParams, setDepositLimitFraction,
//              collectInsurance, collectStability, setDEX, setPriceOracle
//
// Note: withdrawStabilityFund (EGovernance) requires an active stability fund
// (non-zero debit balance + elapsed time + non-zero fee rate) and is therefore
// covered by the dedicated withdraw_stability_funds_test.cdc.

/// EGovernance cap allows Pool.pausePool and Pool.unpausePool.
access(all)
fun testEGovernance_PauseUnpause() {
    safeReset()

    let pauseResult = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_pool_paused.cdc",
        [true],
        eGovernanceUser
    )
    Test.expect(pauseResult, Test.beSucceeded())

    let unpauseResult = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_pool_paused.cdc",
        [false],
        eGovernanceUser
    )
    Test.expect(unpauseResult, Test.beSucceeded())
}

/// EGovernance cap allows Pool.addSupportedToken.
/// FlowToken is not added in setup, so this exercises a fresh token addition.
access(all)
fun testEGovernance_AddSupportedToken() {
    safeReset()

    // Oracle price for FlowToken is needed before using it as collateral/borrow,
    // but adding a token to the pool does not require a price.
    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/add_supported_token.cdc",
        [FLOW_TOKEN_IDENTIFIER, 0.8, 0.8, 1_000_000.0, 1_000_000.0],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.setInterestCurve.
access(all)
fun testEGovernance_SetInterestCurve() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_interest_curve.cdc",
        [MOET_TOKEN_IDENTIFIER, 0.05 as UFix128],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.setInsuranceRate.
/// Uses rate=0.0 because a non-zero rate requires an insurance swapper to be configured;
/// a zero rate still exercises the EGovernance entitlement check without that prerequisite.
access(all)
fun testEGovernance_SetInsuranceRate() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_insurance_rate.cdc",
        [MOET_TOKEN_IDENTIFIER, 0.0],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.setStabilityFeeRate.
access(all)
fun testEGovernance_SetStabilityFeeRate() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_stability_fee_rate.cdc",
        [MOET_TOKEN_IDENTIFIER, 0.05],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.setLiquidationParams (via borrowConfig).
access(all)
fun testEGovernance_SetLiquidationParams() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_liquidation_params.cdc",
        [1.05 as UFix128],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.setPauseParams (via borrowConfig).
access(all)
fun testEGovernance_SetPauseParams() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_pause_params.cdc",
        [300 as UInt64],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.setDepositLimitFraction.
access(all)
fun testEGovernance_SetDepositLimitFraction() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_deposit_limit_fraction.cdc",
        [MOET_TOKEN_IDENTIFIER, 0.10],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.collectInsurance.
/// No insurance has accrued (zero insurance rate), but the call itself is valid.
access(all)
fun testEGovernance_CollectInsurance() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/collect_insurance.cdc",
        [MOET_TOKEN_IDENTIFIER],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.collectStability.
/// No stability fees have accrued (zero stability rate), but the call itself is valid.
access(all)
fun testEGovernance_CollectStability() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/collect_stability.cdc",
        [MOET_TOKEN_IDENTIFIER],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.setDEX (via borrowConfig).
/// Uses MockDexSwapper.SwapperProvider as the DEX implementation.
access(all)
fun testEGovernance_SetDEX() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_dex.cdc",
        [],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

/// EGovernance cap allows Pool.setPriceOracle.
/// Uses MockOracle.PriceOracle whose unitOfAccount matches the pool's default token (MOET).
access(all)
fun testEGovernance_SetPriceOracle() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_oracle.cdc",
        [],
        eGovernanceUser
    )
    Test.expect(result, Test.beSucceeded())
}

// =============================================================================
// EImplementation — protocol internals (never issued externally)
// =============================================================================
//
// Actor: PROTOCOL_ACCOUNT — pool owner; EImplementation via direct storage borrow.
// Matrix rows: asyncUpdate, asyncUpdatePosition, regenerateAllDepositCapacities

/// EImplementation allows Pool.asyncUpdate.
/// The queue may be empty in tests; asyncUpdate is a no-op when the queue is empty.
access(all)
fun testEImplementation_AsyncUpdate() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eimplementation/async_update.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(result, Test.beSucceeded())
}

/// EImplementation allows Pool.asyncUpdatePosition.
access(all)
fun testEImplementation_AsyncUpdatePosition() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eimplementation/async_update_position.cdc",
        [setupPid],
        PROTOCOL_ACCOUNT
    )
    Test.expect(result, Test.beSucceeded())
}

/// EImplementation allows Pool.regenerateAllDepositCapacities.
access(all)
fun testEImplementation_RegenerateAllDepositCapacities() {
    safeReset()

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/eimplementation/regenerate_capacities.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(result, Test.beSucceeded())
}
