import Test

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0

access(all) let defaultTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all)
fun setup() {
    deployContracts()
    var err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [defaultTokenIdentifier]
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "MockTidalProtocolConsumer",
        path: "../contracts/mocks/MockTidalProtocolConsumer.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    snapshot = getCurrentBlockHeight()
}

access(all)
fun testRebalanceUndercollateralised() {
    Test.reset(to: snapshot)
    let initialPrice = 1.0
    let priceDropPct: UFix64 = 0.2
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialPrice)

    // pool + token support
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    // open position
    let openRes = executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let healthBefore = getPositionHealth(pid: 0, beFailed: false)

    // drop price
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialPrice * (1.0 - priceDropPct))

    let availableAfterPriceChange = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: true, beFailed: false)
    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

    let healthAfterRebalance = getPositionHealth(pid: 0, beFailed: false)

    Test.assert(healthBefore > healthAfterPriceChange) // health decreased after drop
    Test.assert(healthAfterRebalance > healthAfterPriceChange) // health improved after rebalance
} 