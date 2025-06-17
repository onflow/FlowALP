import Test

import "MOET"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Pool Creation Workflow Test
// -----------------------------------------------------------------------------
// Validates that a pool can be created and that essential invariants hold.
// -----------------------------------------------------------------------------

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0

access(all) let defaultTokenIdentifier = "A.0000000000000007.MOET.Vault"

// -----------------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------------
access(all)
fun setup() {
    deployContracts()

    // deploy mocks required for pool creation (oracle etc.) – not strictly needed here
    var err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [defaultTokenIdentifier]
    )
    Test.expect(err, Test.beNil())

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
// TEST CASES
// -----------------------------------------------------------------------------

access(all)
fun testPoolCreationSucceeds() {
    // --- act ---------------------------------------------------------------
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // --- assert ------------------------------------------------------------
    let exists = poolExists(address: protocolAccount.address)
    Test.assert(exists)

    // Reserve balance should be zero for default token
    let reserveBal = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assertEqual(0.0, reserveBal)
} 