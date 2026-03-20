import Test
import BlockchainHelpers
import "FlowALPv0"

import "MOET"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testRebalanceOvercollateralised() {
    // Test.reset(to: snapshot)
    let initialPrice = 1.0
    let priceIncreasePct: UFix64 = 1.2
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: initialPrice)

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

    // Grant beta access to user so they can create positions
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let healthBefore = getPositionHealth(pid: 0, beFailed: false)

    let detailsBefore = getPositionDetails(pid: 0, beFailed: false)

    log(detailsBefore.balances[0].balance)

    // This logs 615.38... which is the auto-borrowed MOET amount
    // The position started with 1000 Flow collateral but immediately borrowed
    // 615.38 MOET due to pushToDrawDownSink=true triggering auto-rebalancing

    // increase price
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice * priceIncreasePct)

    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    // After a 20% price increase, health should be at least 1.5 (=960/615.38)
    Test.assert(healthAfterPriceChange >= INT_MAX_HEALTH,
        message: "Expected health after price increase to be >= 1.5 but got ".concat(healthAfterPriceChange.toString()))

    rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 0, force: true, beFailed: false)

    let healthAfterRebalance = getPositionHealth(pid: 0, beFailed: false)

    Test.assert(healthAfterPriceChange > healthBefore) // got healthier due to price increase
    Test.assert(healthAfterRebalance < healthAfterPriceChange) // health decreased after drawing down excess collateral

    let detailsAfterRebalance = getPositionDetails(pid: 0, beFailed: false)

    // Expected debt after rebalance: effective collateral (post-price) / targetHealth
    // 1000 Flow at price 1.2 = 1200, collateralFactor 0.8 -> 960 effective collateral
    // targetHealth = 1.3 → effective debt = 960 / 1.3 ≈ 738.4615
    let expectedDebt: UFix64 = 960.0 / 1.3

    var actualDebt: UFix64 = 0.0
    for bal in detailsAfterRebalance.balances {
        if bal.vaultType.identifier == MOET_TOKEN_IDENTIFIER {
            actualDebt = bal.balance
        }
    }

    let tolerance: UFix64 = 0.01
    Test.assert((actualDebt >= expectedDebt - tolerance) && (actualDebt <= expectedDebt + tolerance))

    // Ensure the borrowed MOET after rebalance actually reached the user's Vault
    let userMoetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(userMoetBalance >= expectedDebt - tolerance && userMoetBalance <= expectedDebt + tolerance,
        message: "User MOET balance should reflect new debt (~".concat(expectedDebt.toString()).concat(") but was ").concat(userMoetBalance.toString()))
}

/// Verifies that depositAndPush with pushToDrawDownSink=true always
/// rebalances the position back to targetHealth at deposit time by
/// pushing excess value to the sink.
access(all)
fun testDepositAndPush_rebalancesToTargetHealth() {
    Test.reset(to: snapshot)

    let initialPrice = 1.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: initialPrice)

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
    mintFlow(to: user, amount: 1_100.0)
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
    Test.assert(equalWithinVariance(INT_TARGET_HEALTH, healthBefore),
        message: "Position should start at target health (~1.3) but was ".concat(healthBefore.toString()))

    // Deposit 100 more FLOW with pushToDrawDownSink=true.
    // The push always triggers at deposit time, restoring targetHealth.
    depositToPosition(
        signer: user,
        positionID: 0,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: true
    )

    let healthAfter = getPositionHealth(pid: 0, beFailed: false)
    Test.assert(equalWithinVariance(INT_TARGET_HEALTH, healthAfter),
        message: "With pushToDrawDownSink=true, position should be rebalanced to target health (~1.3) but health was ".concat(healthAfter.toString()))
}
