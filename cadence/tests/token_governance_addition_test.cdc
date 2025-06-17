import Test

import "MOET"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Token Governance Addition Test
// -----------------------------------------------------------------------------

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0

access(all) let defaultTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"

access(all)
fun setup() {
    deployContracts()

    var err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [defaultTokenIdentifier]
    )
    Test.expect(err, Test.beNil())

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
access(all)
fun testAddSupportedTokenSucceedsAndDuplicateFails() {
    // ensure fresh state
    Test.reset(to: snapshot)

    // create pool first
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // add FLOW token support
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // attempt duplicate addition – should fail
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
} 