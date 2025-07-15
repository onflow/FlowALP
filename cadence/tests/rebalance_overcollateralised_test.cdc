import Test
import BlockchainHelpers
import "TidalProtocol"

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault

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
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialPrice)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: initialPrice)

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    let openRes = executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],
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
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialPrice * priceIncreasePct)

    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    // After a 20% price increase, health should be at least 1.5 (=960/615.38)
    Test.assert(healthAfterPriceChange >= intMaxHealth,
        message: "Expected health after price increase to be >= 1.5 but got ".concat(healthAfterPriceChange.toString()))

    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

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
        if bal.vaultType.identifier == moetTokenIdentifier {
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