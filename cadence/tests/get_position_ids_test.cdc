import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// getPositionIDs Test
//
// Verifies that Pool.getPositionIDs() correctly reflects opened and closed
// positions via the get_position_ids.cdc script.
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    snapshot = getCurrentBlockHeight()
}

// Helper: call the get_position_ids script and return the result array
access(all)
fun getPositionIDs(): [UInt64] {
    let res = _executeScript(
        "../scripts/flow-alp/get_position_ids.cdc",
        [PROTOCOL_ACCOUNT.address, UInt64(0)]
    )
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! [UInt64]
}

// Helper: repay and close a position by ID
access(all)
fun closePosition(user: Test.TestAccount, positionID: UInt64) {
    let res = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [positionID],
        user
    )
    Test.expect(res, Test.beSucceeded())
}

// =============================================================================
// Test: getPositionIDs tracks opens and closes correctly
// =============================================================================
access(all)
fun test_getPositionIDs_lifecycle() {
    // --- Setup ---
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // --- No positions yet ---
    var ids = getPositionIDs()
    Test.assertEqual(0, ids.length)

    // --- Open position 0 (with borrow) ---
    let open0 = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(open0, Test.beSucceeded())

    ids = getPositionIDs()
    Test.assertEqual(1, ids.length)
    Test.assert(ids.contains(UInt64(0)), message: "Expected position 0 in IDs")

    // --- Open position 1 (with borrow) ---
    let open1 = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(open1, Test.beSucceeded())

    ids = getPositionIDs()
    Test.assertEqual(2, ids.length)
    Test.assert(ids.contains(UInt64(0)), message: "Expected position 0 in IDs")
    Test.assert(ids.contains(UInt64(1)), message: "Expected position 1 in IDs")

    // --- Open position 2 (no borrow, so closing won't need MOET repay) ---
    let open2 = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(open2, Test.beSucceeded())

    ids = getPositionIDs()
    Test.assertEqual(3, ids.length)
    Test.assert(ids.contains(UInt64(2)), message: "Expected position 2 in IDs")

    // --- Close position 2 (no debt, straightforward) ---
    closePosition(user: user, positionID: 2)

    ids = getPositionIDs()
    Test.assertEqual(2, ids.length)
    Test.assert(!ids.contains(UInt64(2)), message: "Position 2 should be removed after close")
    Test.assert(ids.contains(UInt64(0)), message: "Position 0 should still exist")
    Test.assert(ids.contains(UInt64(1)), message: "Position 1 should still exist")

    // --- Close position 0 (has debt, repay needed) ---
    closePosition(user: user, positionID: 0)

    ids = getPositionIDs()
    Test.assertEqual(1, ids.length)
    Test.assert(!ids.contains(UInt64(0)), message: "Position 0 should be removed after close")
    Test.assert(ids.contains(UInt64(1)), message: "Position 1 should still exist")

    // --- Open position 3 (new position after some closures) ---
    let open3 = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(open3, Test.beSucceeded())

    ids = getPositionIDs()
    Test.assertEqual(2, ids.length)
    Test.assert(ids.contains(UInt64(1)), message: "Position 1 should still exist")
    Test.assert(ids.contains(UInt64(3)), message: "Expected position 3 in IDs")

    // --- Close remaining positions ---
    closePosition(user: user, positionID: 1)
    closePosition(user: user, positionID: 3)

    ids = getPositionIDs()
    Test.assertEqual(0, ids.length)
}
