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
}
