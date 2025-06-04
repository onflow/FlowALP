import Test
import BlockchainHelpers

import "MOET"

import "test_helpers.cdc"

/*
    Platform integration tests covering the path used by platforms using TidalProtocol to create
    and manage new positions. These tests currently only cover the happy path, ensuring that
    transactions creating & updating positions succeed.
 */

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
    err = Test.deployContract(
        name: "FungibleTokenStack",
        path: "../../DeFiBlocks/cadence/contracts/connectors/FungibleTokenStack.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all)
fun testDeploymentSucceeds() {
    log("Success: contracts deployed")
}

access(all)
fun testCreatePoolSucceeds() {
    snapshot = getCurrentBlockHeight()

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    let existsRes = executeScript("../scripts/tidal-protocol/pool_exists.cdc", [protocolAccount.address])
    Test.expect(existsRes, Test.beSucceeded())

    let exists = existsRes.returnValue as! Bool
    Test.assert(exists)
}

access(all)
fun testCreatePositionSucceeds() {
    Test.reset(to: snapshot)

    // mock setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // create pool & add FLOW as supported token in globalLedger
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1000000.0,
        depositCapacityCap: 1000000.0
    )

    // act as user setting up a Position
    let user = Test.createAccount()
    mintFlow(to: user, amount: 100.0)
    let res = executeTransaction("./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
            [10.0, flowVaultStoragePath, true], // amount, vaultStoragePath, pushToDrawDownSink
            user
        )
    Test.expect(res, Test.beSucceeded())

    log(getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath))
}
