import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// tryGetPositionDetails Test
//
// Verifies that Pool.tryGetPositionDetails() returns position details for
// existing positions and nil for non-existent or closed positions.
// -----------------------------------------------------------------------------

access(all)
fun setup() {
    deployContracts()
}

// =============================================================================
// Test: tryGetPositionDetails returns details for open positions and nil otherwise
// =============================================================================
access(all)
fun test_tryGetPositionDetails() {
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

    // --- Non-existent position returns nil ---
    let nonExistent = tryGetPositionDetails(pid: 0)
    Test.assertEqual(nil, nonExistent)

    // --- Open a position ---
    createPosition(signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // --- Existing position returns details ---
    let details = tryGetPositionDetails(pid: 0)
    Test.assert(details != nil, message: "Expected non-nil details for open position")

    // --- Result matches getPositionDetails ---
    let expected = getPositionDetails(pid: 0, beFailed: false)
    Test.assertEqual(expected.health, details!.health)
    Test.assertEqual(expected.balances.length, details!.balances.length)

    // --- Still nil for non-existent ID ---
    let stillNil = tryGetPositionDetails(pid: 999)
    Test.assertEqual(nil, stillNil)

    // --- Close the position, should return nil ---
    closePosition(user: user, positionID: 0)
    let afterClose = tryGetPositionDetails(pid: 0)
    Test.assertEqual(nil, afterClose)
}
