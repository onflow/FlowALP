import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Token Governance Addition Test
// -----------------------------------------------------------------------------

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
access(all)
fun testAddSupportedTokenSucceedsAndDuplicateFails() {

    // create pool first
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // add FLOW token support
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // attempt duplicate addition – should fail
    let res = addSupportedTokenZeroRateCurveWithResult(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    Test.expect(res, Test.beFailed())
} 