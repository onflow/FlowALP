import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Pool Creation Workflow Test
// -----------------------------------------------------------------------------
// Validates that a pool can be created and that essential invariants hold.
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

// -----------------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------------
access(all)
fun setup() {
    deployContracts()

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    let exists = poolExists(address: PROTOCOL_ACCOUNT.address)
    Test.assert(exists)

    // Reserve balance should be zero for default token
    let reserveBal = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(0.0, reserveBal)

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
// TEST CASES
// -----------------------------------------------------------------------------

access(all)
fun testPositionCreationFail() {

    let txResult = _executeTransaction(
        "../tests/transactions/flow-credit-market/pool-management/01_negative_no_eparticipant_fail.cdc",
        [],
        PROTOCOL_ACCOUNT
    )
    Test.expect(txResult, Test.beFailed())
}

access(all)
fun testPositionCreationSuccess() {
    Test.reset(to: snapshot)

    let txResult = _executeTransaction(
        "../tests/transactions/flow-credit-market/pool-management/02_positive_with_eparticipant_pass.cdc",
        [],
        PROTOCOL_ACCOUNT
    )

    Test.expect(txResult, Test.beSucceeded())
} 

access(all)
fun testNegativeCap() {
    Test.reset(to: snapshot)

    let negativeResult = _executeTransaction("../tests/transactions/flow-credit-market/pool-management/05_negative_cap.cdc", [], CONSUMER_ACCOUNT)
    Test.expect(negativeResult, Test.beFailed())
}

access(all)
fun testPublishClaimCap() {
    Test.reset(to: snapshot)
    
    let publishCapResult = _executeTransaction("../transactions/flow-credit-market/beta/publish_beta_cap.cdc", [PROTOCOL_ACCOUNT.address], PROTOCOL_ACCOUNT)
    Test.expect(publishCapResult, Test.beSucceeded())

    let claimCapResult = _executeTransaction("../transactions/flow-credit-market/beta/claim_and_save_beta_cap.cdc", [PROTOCOL_ACCOUNT.address], PROTOCOL_ACCOUNT)
    Test.expect(claimCapResult, Test.beSucceeded())

    let createPositionResult = _executeTransaction("../tests/transactions/flow-credit-market/pool-management/04_create_position.cdc", [], PROTOCOL_ACCOUNT)
}
