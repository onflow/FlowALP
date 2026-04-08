import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// getOpenPositionIDs Test
//
// Verifies that get_open_position_ids.cdc correctly returns only IDs of
// positions that have at least one non-zero balance.
// -----------------------------------------------------------------------------

access(all)
fun setup() {
    deployContracts()
}

// =============================================================================
// Test: getOpenPositionIDs tracks opens and closes correctly
// =============================================================================
access(all)
fun test_getOpenPositionIDs_lifecycle() {
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

    // --- No positions yet ---
    var ids = getOpenPositionIDs()
    Test.assertEqual(0, ids.length)

    // --- Open position 0 (no borrow) ---
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    ids = getOpenPositionIDs()
    Test.assertEqual(1, ids.length)
    Test.assert(ids.contains(UInt64(0)), message: "Expected position 0 in IDs")

    // --- Open position 1 (no borrow) ---
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 200.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    ids = getOpenPositionIDs()
    Test.assertEqual(2, ids.length)
    Test.assert(ids.contains(UInt64(0)), message: "Expected position 0 in IDs")
    Test.assert(ids.contains(UInt64(1)), message: "Expected position 1 in IDs")

    // --- Close position 0 ---
    closePosition(user: user, positionID: 0)

    ids = getOpenPositionIDs()
    Test.assertEqual(1, ids.length)
    Test.assert(!ids.contains(UInt64(0)), message: "Position 0 should be removed after close")
    Test.assert(ids.contains(UInt64(1)), message: "Position 1 should still exist")

    // --- Open position 2 ---
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    ids = getOpenPositionIDs()
    Test.assertEqual(2, ids.length)
    Test.assert(ids.contains(UInt64(1)), message: "Position 1 should still exist")
    Test.assert(ids.contains(UInt64(2)), message: "Expected position 2 in IDs")

    // --- Close remaining positions ---
    closePosition(user: user, positionID: 1)
    closePosition(user: user, positionID: 2)

    ids = getOpenPositionIDs()
    Test.assertEqual(0, ids.length)
}
