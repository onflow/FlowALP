import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv1"
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
        "./transactions/position-manager/set_min_health.cdc",
        [positionId, 0.9 as UFix64],
        user
    )
    Test.expect(setRes, Test.beFailed())
    Test.assertError(setRes, errorMessage: "must be >1")
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

    // Lower minHealth to 0.01 so the preflight check won't block the withdrawal.
    // This bypasses the minHealth preflight, letting us test the hard health >= 1.0 invariant.
    let setRes = _executeTransaction(
        "./transactions/position-manager/set_min_health.cdc",
        [positionId, 0.01 as UFix64],
        user
    )
    Test.expect(setRes, Test.beSucceeded())

    // After opening, the position has:
    //   collateral = 1000 Flow, effective collateral = 800 (CF=0.8)
    //   debt ~ 615.38 MOET (to reach target health 1.3)
    //   health = 800 / 615.38 ~ 1.3
    //
    // Withdrawing 250 Flow would leave 750 Flow collateral, effective = 600.
    // health = 600 / 615.38 ~ 0.975, below 1.0.
    let withdrawRes = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [positionId, FLOW_TOKEN_IDENTIFIER, 250.0, false],
        user
    )
    Test.expect(withdrawRes, Test.beFailed())
    Test.assertError(withdrawRes, errorMessage: "is unhealthy")
}
