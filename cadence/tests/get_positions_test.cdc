import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// get_positions.cdc Test
//
// Verifies paginated retrieval of position details via startIndex and count.
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Test: pagination returns correct slices of positions
// =============================================================================
access(all)
fun test_getPositions_pagination() {
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

    // --- Empty pool ---
    var positions = getPositions(startIndex: 0, count: 10)
    Test.assertEqual(0, positions.length)

    // --- Open 4 positions (no borrow for easy cleanup) ---
    createPosition(signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    createPosition(signer: user, amount: 200.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    createPosition(signer: user, amount: 300.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    createPosition(signer: user, amount: 400.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // --- Fetch all at once ---
    positions = getPositions(startIndex: 0, count: 10)
    Test.assertEqual(4, positions.length)

    // --- Fetch first 2 ---
    positions = getPositions(startIndex: 0, count: 2)
    Test.assertEqual(2, positions.length)

    // --- Fetch next 2 ---
    positions = getPositions(startIndex: 2, count: 2)
    Test.assertEqual(2, positions.length)

    // --- Fetch with startIndex beyond length ---
    positions = getPositions(startIndex: 10, count: 5)
    Test.assertEqual(0, positions.length)

    // --- Fetch with count exceeding remaining ---
    positions = getPositions(startIndex: 3, count: 100)
    Test.assertEqual(1, positions.length)

    // --- Close position 1, verify pagination reflects removal ---
    closePosition(user: user, positionID: 1)

    positions = getPositions(startIndex: 0, count: 10)
    Test.assertEqual(3, positions.length)

    // First page of 2
    positions = getPositions(startIndex: 0, count: 2)
    Test.assertEqual(2, positions.length)

    // Second page
    positions = getPositions(startIndex: 2, count: 2)
    Test.assertEqual(1, positions.length)
}
