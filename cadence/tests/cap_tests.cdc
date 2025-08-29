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
fun testPositionCreationFail() {
    // --- act ---------------------------------------------------------------
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // --- assert ------------------------------------------------------------
    let exists = poolExists(address: protocolAccount.address)
    Test.assert(exists)

    // Reserve balance should be zero for default token
    let reserveBal = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assertEqual(0.0, reserveBal)

    let txResult = _executeTransaction(
        "../tests/transactions/tidal-protocol/pool-management/01_negative_no_eparticipant_fail.cdc",
        [],
        protocolAccount
    )
    Test.expect(txResult, Test.beFailed())
} 

access(all)
fun testPositionCreationSuccess() {
    Test.reset(to: snapshot)
    // --- act ---------------------------------------------------------------
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // --- assert ------------------------------------------------------------
    let exists = poolExists(address: protocolAccount.address)
    Test.assert(exists)

    // Reserve balance should be zero for default token
    let reserveBal = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assertEqual(0.0, reserveBal)

    let txResult = _executeTransaction(
        "../tests/transactions/tidal-protocol/pool-management/02_positive_with_eparticipant_pass.cdc",
        [],
        protocolAccount
    )

    Test.expect(txResult, Test.beSucceeded())
} 
