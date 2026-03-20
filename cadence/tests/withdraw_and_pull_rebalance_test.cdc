import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

/// Verifies that withdrawAndPull with pullFromTopUpSource=true rebalances
/// the position back to targetHealth, not just minHealth.
///
/// Setup:
///   - User deposits 1000 FLOW (price=1.0, CF=0.8) with auto-borrow.
///   - Position starts at targetHealth=1.3 with ~615.38 MOET debt.
///   - User's MOET vault (topUpSource) holds ~615.38 MOET.
///
/// Action:
///   - Withdraw a small FLOW amount that drops health below targetHealth
///     but keeps it above minHealth (1.1).
///   - Use pullFromTopUpSource=true.
///
/// Expected (consistent with depositAndPush):
///   - The protocol should pull from the topUpSource to rebalance
///     back to targetHealth, not just leave the position between
///     minHealth and targetHealth.
access(all)
fun test_withdrawAndPull_rebalancesToTargetHealth() {
    let initialPrice = 1.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with auto-borrow: deposits 1000 FLOW, borrows ~615.38 MOET.
    // Health starts at targetHealth (1.3).
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let healthBefore = getPositionHealth(pid: 0, beFailed: false)
    let tolerance: UFix128 = 0.01
    Test.assert(
        healthBefore >= INT_TARGET_HEALTH - tolerance && healthBefore <= INT_TARGET_HEALTH + tolerance,
        message: "Position should start at target health (~1.3) but was ".concat(healthBefore.toString())
    )

    // Withdraw 50 FLOW with pullFromTopUpSource=true.
    // Without the fix: health drops below targetHealth but stays above minHealth,
    // so pullFromTopUpSource is ignored and the position is NOT rebalanced.
    // With the fix: the protocol should pull from topUpSource to restore targetHealth.
    withdrawFromPosition(
        signer: user,
        positionId: 0,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 50.0,
        pullFromTopUpSource: true
    )

    let healthAfter = getPositionHealth(pid: 0, beFailed: false)

    // The position health should be restored to targetHealth (1.3),
    // NOT left between minHealth and targetHealth.
    Test.assert(
        healthAfter >= INT_TARGET_HEALTH - tolerance,
        message: "With pullFromTopUpSource=true, position should be rebalanced to target health (~1.3) but health was ".concat(healthAfter.toString())
    )
}
