import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// getOpenPositionsByIDs Test
//
// Verifies that the get_open_positions_by_ids.cdc script correctly returns
// position details only for open positions (those with non-zero balances).
// -----------------------------------------------------------------------------

access(all)
fun setup() {
    deployContracts()
}

// =============================================================================
// Test: getOpenPositionsByIDs returns correct details and filters closed
// =============================================================================
access(all)
fun test_getOpenPositionsByIDs() {
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

    // --- Open two positions (no borrow to avoid MOET cross-contamination) ---
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 200.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // --- Fetch both positions by IDs ---
    let details = getOpenPositionsByIDs(positionIDs: [UInt64(0), UInt64(1)])
    Test.assertEqual(2, details.length)

    // Verify each result matches the single-position helper
    let details0 = getPositionDetails(pid: 0, beFailed: false)
    let details1 = getPositionDetails(pid: 1, beFailed: false)

    Test.assertEqual(details0.health, details[0].health)
    Test.assertEqual(details0.balances.length, details[0].balances.length)

    Test.assertEqual(details1.health, details[1].health)
    Test.assertEqual(details1.balances.length, details[1].balances.length)

    // --- Empty input returns empty array ---
    let emptyDetails = getOpenPositionsByIDs(positionIDs: [])
    Test.assertEqual(0, emptyDetails.length)

    // --- Single ID works ---
    let singleDetails = getOpenPositionsByIDs(positionIDs: [UInt64(0)])
    Test.assertEqual(1, singleDetails.length)
    Test.assertEqual(details0.health, singleDetails[0].health)

    // --- Close position 1 and verify it's filtered out ---
    closePosition(user: user, positionID: 1)

    let afterClose = getOpenPositionsByIDs(positionIDs: [UInt64(0), UInt64(1)])
    Test.assertEqual(1, afterClose.length)
    Test.assertEqual(details0.health, afterClose[0].health)
}
