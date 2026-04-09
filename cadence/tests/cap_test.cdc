import Test
import BlockchainHelpers

import "MOET"
import "FlowALPEvents"
import "FlowALPModels"
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


// Position created for PROTOCOL_ACCOUNT in setup — used as target for ERebalance tests.
access(all) var setupPid: UInt64 = 0
access(all) var ePositionAdminPid: UInt64 = 0

access(all) var snapshot: UInt64 = 0

// Role accounts
access(all) var userWithoutCap = Test.createAccount()
access(all) var eParticipantUser = Test.createAccount()
access(all) var eRebalanceUser = Test.createAccount()
access(all) var ePositionAdminUser = Test.createAccount()
access(all) var eGovernanceUser = Test.createAccount()

/// Returns all role accounts that do NOT hold an EGovernance capability.
/// Used in negative tests to verify governance methods are inaccessible to them.
access(all)
fun getNonGovernanceUsers(): [Test.TestAccount] {
    return [eParticipantUser, eRebalanceUser, ePositionAdminUser]
}

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
    // user without any capability
    // ─────────────────────────────────────────────────────────────────────────
    setupMoetVault(userWithoutCap, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: userWithoutCap.address, amount: 100.0, beFailed: false)

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
    Test.assert(getLastPositionId() > ePositionAdminPid, message: "Expected a new position to be created")
}

// =============================================================================
// EParticipant — fixed beta capability (EParticipant only)
// =============================================================================
//
// Actor: eParticipantUser — Capability<auth(EParticipant) &Pool>
// Matrix rows: createPosition, depositToPosition, manualLiquidation

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

    // Verify position was created and funded: create_and_deposit_via_cap.cdc deposits
    // 5.0 MOET (createPosition) + 1.0 MOET (depositToPosition) = 6.0 MOET credit.
    let newPid = getLastPositionId()
    let creditBalance = getCreditBalanceForType(
        details: getPositionDetails(pid: newPid, beFailed: false),
        vaultType: Type<@MOET.Vault>()
    )
    Test.assertEqual(6.0, creditBalance)
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
    Test.assertEqual(
        getPositionTargetHealth(positionOwner: ePositionAdminUser.address, pid: ePositionAdminPid),
        TARGET_HEALTH
    )
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
    Test.assertEqual(
        getPositionMinHealth(positionOwner: ePositionAdminUser.address, pid: ePositionAdminPid),
        MIN_HEALTH
    )
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
    Test.assertEqual(
        getPositionMaxHealth(positionOwner: ePositionAdminUser.address, pid: ePositionAdminPid),
        MAX_HEALTH
    )
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
    Test.assertEqual(1, Test.eventsOfType(Type<FlowALPEvents.PoolPaused>()).length)

    let unpauseResult = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance/set_pool_paused.cdc",
        [false],
        eGovernanceUser
    )
    Test.expect(unpauseResult, Test.beSucceeded())
    Test.assertEqual(1, Test.eventsOfType(Type<FlowALPEvents.PoolUnpaused>()).length)
}

/// Negative: no non-governance entitlement can call Pool.pausePool / unpausePool.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_PauseUnpause_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_pool_paused.cdc",
            [true],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_pool_paused_without_auth.cdc",
        [true, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
    // Verify the token was added: deposit capacity cap should match the value passed in.
    let info = getDepositCapacityInfo(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assertEqual(1_000_000.0, info["depositCapacityCap"]!)
}

/// Negative: no non-governance entitlement can call Pool.addSupportedToken.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_AddSupportedToken_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_add_supported_token.cdc",
            [FLOW_TOKEN_IDENTIFIER, 0.8, 0.8, 1_000_000.0, 1_000_000.0],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_add_supported_token_without_auth.cdc",
        [FLOW_TOKEN_IDENTIFIER, 0.8, 0.8, 1_000_000.0, 1_000_000.0, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
    // Verify the curve was stored: read back yearlyRate for the FixedCurve.
    let curveRes = _executeScript("../scripts/flow-alp/get_interest_curve_params.cdc", [MOET_TOKEN_IDENTIFIER])
    Test.expect(curveRes, Test.beSucceeded())
    let curveParams = curveRes.returnValue as! {String: AnyStruct}?
    Test.assert(curveParams != nil, message: "Expected interest curve params to be set")
    let yearlyRate = curveParams!["yearlyRate"] as! UFix128
    Test.assertEqual(0.05 as UFix128, yearlyRate)
}

/// Negative: no non-governance entitlement can call Pool.setInterestCurve.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_SetInterestCurve_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_interest_curve.cdc",
            [MOET_TOKEN_IDENTIFIER, 0.05 as UFix128],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_interest_curve_without_auth.cdc",
        [MOET_TOKEN_IDENTIFIER, 0.05 as UFix128, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
    // Verify the rate was stored (0.0 is valid without a swapper; confirms the setter ran).
    Test.assertEqual(0.0, getInsuranceRate(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)!)
}

/// Negative: ERebalance cap cannot call Pool.setInsuranceRate (EGovernance required).
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_SetInsuranceRate_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_insurance_rate.cdc",
            [MOET_TOKEN_IDENTIFIER, 0.0],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_insurance_rate_without_auth.cdc",
        [MOET_TOKEN_IDENTIFIER, 0.0, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
    // Verify the new rate was stored (changed from default 0.0).
    Test.assertEqual(0.05, getStabilityFeeRate(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)!)
}

/// Negative: no non-governance entitlement can call Pool.setStabilityFeeRate.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_SetStabilityFeeRate_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_stability_fee_rate.cdc",
            [MOET_TOKEN_IDENTIFIER, 0.05],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_stability_fee_rate_without_auth.cdc",
        [MOET_TOKEN_IDENTIFIER, 0.05, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
    // Verify the target health factor was stored.
    let liqRes = _executeScript("../scripts/flow-alp/get_liquidation_params.cdc", [])
    Test.expect(liqRes, Test.beSucceeded())
    let liqParams = liqRes.returnValue as! FlowALPModels.LiquidationParamsView
    Test.assertEqual(1.05 as UFix128, liqParams.targetHF)
}

/// Negative: no non-governance entitlement can call Pool.borrowConfig / setLiquidationTargetHF.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_SetLiquidationParams_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_liquidation_params.cdc",
            [1.05 as UFix128],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_liquidation_params_without_auth.cdc",
        [1.05 as UFix128, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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

/// Negative: no non-governance entitlement can call Pool.borrowConfig / setWarmupSec.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_SetPauseParams_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_pause_params.cdc",
            [300 as UInt64],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_pause_params_without_auth.cdc",
        [300 as UInt64, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
    Test.assertEqual(getDepositCapacityInfo(vaultIdentifier: MOET_TOKEN_IDENTIFIER)["depositLimitFraction"]!, 0.10)
}

/// Negative: no non-governance entitlement can call Pool.setDepositLimitFraction.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_SetDepositLimitFraction_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_deposit_limit_fraction.cdc",
            [MOET_TOKEN_IDENTIFIER, 0.10],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_deposit_limit_fraction_without_auth.cdc",
        [MOET_TOKEN_IDENTIFIER, 0.10, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
    // Verify the collection timestamp was updated (nil → Some after first collect).
    Test.assert(
        getLastInsuranceCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER) != nil,
        message: "Expected insurance collection time to be set after collect"
    )
}

/// Negative: no non-governance entitlement can call Pool.collectInsurance.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_CollectInsurance_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_collect_insurance.cdc",
            [MOET_TOKEN_IDENTIFIER],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_collect_insurance_without_auth.cdc",
        [MOET_TOKEN_IDENTIFIER, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
    // Verify the collection timestamp was updated (nil → Some after first collect).
    Test.assert(
        getLastStabilityCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER) != nil,
        message: "Expected stability collection time to be set after collect"
    )
}

/// Negative: no non-governance entitlement can call Pool.collectStability.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_CollectStability_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_collect_stability.cdc",
            [MOET_TOKEN_IDENTIFIER],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_collect_stability_without_auth.cdc",
        [MOET_TOKEN_IDENTIFIER, PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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

/// Negative: no non-governance entitlement can call Pool.borrowConfig / setDex.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_SetDEX_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_dex.cdc",
            [],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_dex_without_auth.cdc",
        [PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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

/// Negative: no non-governance entitlement can call Pool.setPriceOracle.
/// The transaction fails at Cadence check time (type error).
access(all)
fun testEGovernance_SetPriceOracle_NonGovernanceUserFails() {
    safeReset()

    for user in getNonGovernanceUsers() {
        let result = _executeTransaction(
            "../tests/transactions/flow-alp/egovernance_neg/neg_set_oracle.cdc",
            [],
            user
        )
        Test.expect(result, Test.beFailed())
    }

    let result = _executeTransaction(
        "../tests/transactions/flow-alp/egovernance_neg/neg_set_oracle_without_auth.cdc",
        [PROTOCOL_ACCOUNT.address],
        userWithoutCap
    )
    Test.expect(result, Test.beFailed())
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
