import Test

import "MOET"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Position Lifecycle Happy Path Test
// -----------------------------------------------------------------------------

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

// -----------------------------------------------------------------------------
access(all)
fun testPositionLifecycleHappyPath() {
    Test.reset(to: snapshot)

    // price setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // create pool & enable token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // user prep
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    let balanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, balanceBefore)

    // open wrapped position (pushToDrawDownSink)
    let openRes = executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // confirm position open and user borrowed MOET
    let balanceAfterBorrow = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(balanceAfterBorrow > 0.0)

    // repay & close – placeholder, will implement repay txn later
    // TODO when close_position transaction exists
} 