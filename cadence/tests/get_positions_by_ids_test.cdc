import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// getPositionsByIDs Test
//
// Verifies that the get_positions_by_ids.cdc script correctly returns position
// details for the requested IDs.
// -----------------------------------------------------------------------------

access(all)
fun setup() {
    deployContracts()
}

// =============================================================================
// Test: getPositionsByIDs returns correct details for multiple positions
// =============================================================================
access(all)
fun test_getPositionsByIDs() {
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

    // --- Open two positions ---
    createPosition(signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)
    createPosition(signer: user, amount: 200.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // --- Fetch both positions by IDs ---
    let details = getPositionsByIDs(positionIDs: [UInt64(0), UInt64(1)])
    Test.assertEqual(2, details.length)

    // Verify each result matches the single-position helper
    let details0 = getPositionDetails(pid: 0, beFailed: false)
    let details1 = getPositionDetails(pid: 1, beFailed: false)

    Test.assertEqual(details0.health, details[0].health)
    Test.assertEqual(details0.balances.length, details[0].balances.length)

    Test.assertEqual(details1.health, details[1].health)
    Test.assertEqual(details1.balances.length, details[1].balances.length)

    // --- Empty input returns empty array ---
    let emptyDetails = getPositionsByIDs(positionIDs: [])
    Test.assertEqual(0, emptyDetails.length)

    // --- Single ID works ---
    let singleDetails = getPositionsByIDs(positionIDs: [UInt64(0)])
    Test.assertEqual(1, singleDetails.length)
    Test.assertEqual(details0.health, singleDetails[0].health)

    // --- Closed positions are silently skipped ---
    // Close position 1, then request both IDs — should only return position 0
    closePosition(user: user, positionID: 1)
    let afterClose = getPositionsByIDs(positionIDs: [UInt64(0), UInt64(1)])
    Test.assertEqual(1, afterClose.length)
    Test.assertEqual(details0.health, afterClose[0].health)

    // --- All IDs closed/invalid returns empty array ---
    closePosition(user: user, positionID: 0)
    let allClosed = getPositionsByIDs(positionIDs: [UInt64(0), UInt64(1)])
    Test.assertEqual(0, allClosed.length)

    // --- Non-existent IDs are skipped ---
    let nonExistent = getPositionsByIDs(positionIDs: [UInt64(999), UInt64(1000)])
    Test.assertEqual(0, nonExistent.length)
}
