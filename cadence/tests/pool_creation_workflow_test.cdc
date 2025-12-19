import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Pool Creation Workflow Test
// -----------------------------------------------------------------------------
// Validates that a pool can be created and that essential invariants hold.
// -----------------------------------------------------------------------------

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0

// -----------------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------------
access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
// TEST CASES
// -----------------------------------------------------------------------------

access(all)
fun testPoolCreationSucceeds() {
    // --- act ---------------------------------------------------------------
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    // Must be deployed after the Pool is created
    var err = Test.deployContract(
        name: "FlowCreditMarketRegistry",
        path: "../contracts/FlowCreditMarketRegistry.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // --- assert ------------------------------------------------------------
    let exists = poolExists(address: protocolAccount.address)
    Test.assert(exists)

    // Reserve balance should be zero for default token
    let reserveBal = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assertEqual(0.0, reserveBal)
} 