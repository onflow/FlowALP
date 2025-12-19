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
access(all) let testerAccount = Test.getAccount(0x0000000000000008)
access(all) var snapshot: UInt64 = 0

// -----------------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------------
access(all)
fun setup() {
    deployContracts()

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // Must be deployed after the Pool is created
    var err = Test.deployContract(
        name: "FlowCreditMarketRegistry",
        path: "../contracts/FlowCreditMarketRegistry.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    let exists = poolExists(address: protocolAccount.address)
    Test.assert(exists)

    // Reserve balance should be zero for default token
    let reserveBal = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
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
        protocolAccount
    )
    Test.expect(txResult, Test.beFailed())
}

access(all)
fun testPositionCreationSuccess() {
    Test.reset(to: snapshot)

    let txResult = _executeTransaction(
        "../tests/transactions/flow-credit-market/pool-management/02_positive_with_eparticipant_pass.cdc",
        [],
        protocolAccount
    )

    Test.expect(txResult, Test.beSucceeded())
} 

access(all)
fun testNegativeCap() {
    Test.reset(to: snapshot)

    let negativeResult = _executeTransaction("../tests/transactions/flow-credit-market/pool-management/05_negative_cap.cdc", [], testerAccount)
    Test.expect(negativeResult, Test.beFailed())
}

access(all)
fun testPublishClaimCap() {
    Test.reset(to: snapshot)
    
    let publishCapResult = _executeTransaction("../transactions/flow-credit-market/beta/publish_beta_cap.cdc", [protocolAccount.address], protocolAccount)
    Test.expect(publishCapResult, Test.beSucceeded())

    let claimCapResult = _executeTransaction("../transactions/flow-credit-market/beta/claim_and_save_beta_cap.cdc", [protocolAccount.address], protocolAccount)
    Test.expect(claimCapResult, Test.beSucceeded())

    let createPositionResult = _executeTransaction("../tests/transactions/flow-credit-market/pool-management/04_create_position.cdc", [], protocolAccount)
}
