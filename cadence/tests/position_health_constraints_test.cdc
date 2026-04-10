import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Position Health Constraints Tests
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // Oracle: 1 Flow = $1
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Create pool with MOET as default token
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Take snapshot after pool setup, then advance so reset() target is always below current height
    snapshot = getCurrentBlockHeight()
    Test.moveTime(by: 1.0)
}

access(all)
fun beforeEach() {
    Test.reset(to: snapshot)
}

// ---------- helpers ----------------------------------------------------------

/// Creates a user account with Flow tokens and beta access.
access(all)
fun createUser(): Test.TestAccount {
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)
    return user
}

// ---------- tests ------------------------------------------------------------

/// setMinHealth must reject values below 1.0
access(all)
fun test_setMinHealth_fails_below_one() {
    let user = createUser()

    // Open a position with 1000 Flow collateral
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let positionId: UInt64 = 0

    // Attempt to set minHealth to 0.9 (below 1.0) — should fail
    let setRes = _executeTransaction(
        "../transactions/flow-alp/position/set_min_health.cdc",
        [positionId, 0.9 as UFix64],
        user
    )
    Test.expect(setRes, Test.beFailed())
    Test.assertError(setRes, errorMessage: "must be >1")
}

/// setMinHealth must reject values above targetHealth (default 1.3)
access(all)
fun test_setMinHealth_fails_above_target() {
    let user = createUser()

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // minHealth=1.4 exceeds targetHealth=1.3
    let setRes = _executeTransaction(
        "../transactions/flow-alp/position/set_min_health.cdc",
        [0 as UInt64, 1.4 as UFix64],
        user
    )
    Test.expect(setRes, Test.beFailed())
    Test.assertError(setRes, errorMessage: "target health")
}

/// setTargetHealth must reject values at or below minHealth (default 1.1)
access(all)
fun test_setTargetHealth_fails_at_or_below_min() {
    let user = createUser()

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // targetHealth=1.1 equals minHealth — must be strictly greater
    let setRes = _executeTransaction(
        "../transactions/flow-alp/position/set_target_health.cdc",
        [0 as UInt64, 1.1 as UFix64],
        user
    )
    Test.expect(setRes, Test.beFailed())
    Test.assertError(setRes, errorMessage: "must be greater than min health")
}

/// setTargetHealth must reject values at or above maxHealth (default 1.5)
access(all)
fun test_setTargetHealth_fails_at_or_above_max() {
    let user = createUser()

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // targetHealth=1.5 equals maxHealth — must be strictly less
    let setRes = _executeTransaction(
        "../transactions/flow-alp/position/set_target_health.cdc",
        [0 as UInt64, 1.5 as UFix64],
        user
    )
    Test.expect(setRes, Test.beFailed())
    Test.assertError(setRes, errorMessage: "must be less than max health")
}

/// setMaxHealth must reject values below targetHealth (default 1.3)
access(all)
fun test_setMaxHealth_fails_below_target() {
    let user = createUser()

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // maxHealth=1.2 is below targetHealth=1.3
    let setRes = _executeTransaction(
        "../transactions/flow-alp/position/set_max_health.cdc",
        [0 as UInt64, 1.2 as UFix64],
        user
    )
    Test.expect(setRes, Test.beFailed())
    Test.assertError(setRes, errorMessage: "must be greater than target health")
}

/// Withdrawing collateral that would drop health below 1.0 must revert.
access(all)
fun test_withdraw_fails_when_health_drops_below_one() {
    let user = createUser()

    // Open a position with 1000 Flow collateral (auto-borrows to target health 1.3)
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let positionId: UInt64 = 0

    // After opening, the position has:
    //   collateral = 1000 Flow, effective collateral = 800 (CF=0.8)
    //   debt ~ 615.38 MOET (to reach target health 1.3)
    //   health = 800 / 615.38 ~ 1.3
    //
    // Withdrawing 250 Flow would leave 750 Flow collateral, effective = 600.
    // health = 600 / 615.38 ~ 0.975, well below 1.0.
    // The preflight check enforces that withdrawals cannot reduce health below minHealth,
    // which prevents health from ever reaching 1.0.
    let withdrawRes = withdrawFromPosition(
        signer: user,
        positionId: positionId,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        receiverVaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 250.0,
        pullFromTopUpSource: false
    )
    Test.expect(withdrawRes, Test.beFailed())
    Test.assertError(withdrawRes, errorMessage: "Insufficient funds for withdrawal")
}
