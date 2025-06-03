import Test
import BlockchainHelpers

import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)

access(all) var snapshot: UInt64 = 0

access(all) let defaultTokenIdentifier = "A.0000000000000007.MOET.Vault"

access(all)
fun setup() {
    deployContracts()

    var err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [defaultTokenIdentifier]
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