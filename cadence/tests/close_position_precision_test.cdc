import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "FlowALPMath"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Close Position Precision Test Suite
//
// Tests close position functionality with focus on:
// 1. Balance increases (collateral appreciation)
// 2. Balance falls (collateral depreciation)
// 3. Rounding precision and shortfall tolerance
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Test 1: Close position with no debt
// =============================================================================
access(all)
fun test_closePosition_noDebt() {
    log("\n=== Test: Close Position with No Debt ===")

    // Setup: price = 1.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Create pool & enable token
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, collateralFactor: 0.8, borrowFactor: 1.0, depositRate: 1_000_000.0, depositCapacityCap: 1_000_000.0)

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with pushToDrawDownSink = false (no debt)
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Verify no MOET was borrowed
    let moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, moetBalance)

    // Mint tiny buffer to handle any precision shortfall
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 0.01, beFailed: false)

    // Close position (ID 0)
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(0)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed position with no debt")
}

// =============================================================================
// Test 2: Close position with debt
// =============================================================================
access(all)
fun test_closePosition_withDebt() {
    log("\n=== Test: Close Position with Debt ===")

    // Reset price to 1.0 for this test
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Reuse existing pool from previous test
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with pushToDrawDownSink = true (creates debt)
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Verify MOET was borrowed
    let moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    log("Borrowed MOET: \(moetBalance)")
    Test.assert(moetBalance > 0.0)

    // Mint tiny buffer to handle any precision shortfall
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 0.01, beFailed: false)

    // Close position (ID 1 since test 1 created position 0)
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(1)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed position with debt: \(moetBalance) MOET")
}

// =============================================================================
// Test 3: Close after collateral price increase (balance increases)
// =============================================================================
access(all)
fun test_closePosition_afterPriceIncrease() {
    log("\n=== Test: Close After Collateral Price Increase (Balance Increases) ===")

    // Reset price to 1.0 for this test
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Reuse existing pool from previous test
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let detailsBefore = getPositionDetails(pid: 2, beFailed: false)
    log("Health before price increase: \(detailsBefore.health)")

    // Increase FLOW price to 1.5 (50% gain)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.5)
    log("Increased FLOW price to $1.5 (+50%)")

    let detailsAfter = getPositionDetails(pid: 2, beFailed: false)
    log("Health after price increase: \(detailsAfter.health)")
    Test.assert(detailsAfter.health > detailsBefore.health)

    // Mint tiny buffer to handle any precision shortfall
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 0.01, beFailed: false)

    // Close position
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(2)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed after collateral appreciation (balance increased)")
}

// =============================================================================
// Test 4: Close after collateral price decrease (balance falls)
// =============================================================================
access(all)
fun test_closePosition_afterPriceDecrease() {
    log("\n=== Test: Close After Collateral Price Decrease (Balance Falls) ===")

    // Reset price to 1.0 for this test
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Reuse existing pool from previous test
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let detailsBefore = getPositionDetails(pid: 3, beFailed: false)
    log("Health before price decrease: \(detailsBefore.health)")

    // Decrease FLOW price to 0.8 (20% loss)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 0.8)
    log("Decreased FLOW price to $0.8 (-20%)")

    let detailsAfter = getPositionDetails(pid: 3, beFailed: false)
    log("Health after price decrease: \(detailsAfter.health)")
    Test.assert(detailsAfter.health < detailsBefore.health)

    // Mint tiny buffer to handle any precision shortfall
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 0.01, beFailed: false)

    // Close position (should still succeed)
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(3)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed after collateral depreciation (balance fell)")
}

// =============================================================================
// Test 5: Close with precision shortfall after multiple rebalances
// =============================================================================
access(all)
fun test_closePosition_precisionShortfall_multipleRebalances() {
    log("\n=== Test: Close with Precision Shortfall (Multiple Rebalances) ===")

    // Reset price to 1.0 for this test
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Reuse existing pool from previous test
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Perform rebalances with varying prices to accumulate rounding errors
    log("\nRebalance 1: FLOW price = $1.2")
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.2)
    let reb1 = _executeTransaction("../transactions/flow-alp/pool-management/rebalance_position.cdc", [UInt64(4), true], PROTOCOL_ACCOUNT)
    Test.expect(reb1, Test.beSucceeded())

    log("\nRebalance 2: FLOW price = $1.9")
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 0.9)
    let reb2 = _executeTransaction("../transactions/flow-alp/pool-management/rebalance_position.cdc", [UInt64(4), true], PROTOCOL_ACCOUNT)
    Test.expect(reb2, Test.beSucceeded())

    log("\nRebalance 3: FLOW price = $1.5")
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.5)
    let reb3 = _executeTransaction("../transactions/flow-alp/pool-management/rebalance_position.cdc", [UInt64(4), true], PROTOCOL_ACCOUNT)
    Test.expect(reb3, Test.beSucceeded())

    // Get final position state
    let finalDetails = getPositionDetails(pid: 4, beFailed: false)
    log("\n--- Final State ---")
    log("Health: \(finalDetails.health)")
    logBalances(finalDetails.balances)

    // Mint tiny buffer to handle any precision shortfall
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 0.01, beFailed: false)

    // Close position - may have tiny shortfall due to accumulated rounding
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(4)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed after 3 rebalances (precision shortfall automatically handled)")
}

// =============================================================================
// Test 6: Demonstrate precision with extreme volatility
// =============================================================================
access(all)
fun test_closePosition_extremeVolatility() {
    log("\n=== Test: Close After Extreme Price Volatility ===")

    // Reset price to 1.0 for this test
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Reuse existing pool from previous test
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Simulate extreme volatility: 5x gains, 90% drops
    let extremePrices: [UFix64] = [5.0, 0.5, 3.0, 0.2, 4.0, 0.1, 2.0]

    var volCount = 1
    for price in extremePrices {
        log("\nExtreme volatility \(volCount): FLOW = $\(price)")
        setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: price)

        let rebalanceRes = _executeTransaction(
            "../transactions/flow-alp/pool-management/rebalance_position.cdc",
            [UInt64(5), true],
            PROTOCOL_ACCOUNT
        )
        Test.expect(rebalanceRes, Test.beSucceeded())

        let details = getPositionDetails(pid: 5, beFailed: false)
        log("Health: \(details.health)")
        volCount = volCount + 1
    }

    log("\n--- Closing after extreme volatility ---")

    // Mint larger buffer for extreme volatility test (accumulated errors from 7 rebalances)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 1.0, beFailed: false)

    // Close position
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(5)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed after extreme volatility (balance increased/fell dramatically)")
}

// =============================================================================
// Test 7: Close with minimal debt (edge case)
// =============================================================================
access(all)
fun test_closePosition_minimalDebt() {
    log("\n=== Test: Close with Minimal Debt ===")

    // Reset price to 1.0 for this test
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Reuse existing pool from previous test
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with minimal amount
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    log("Minimal debt amount: \(moetBalance) MOET")

    // Mint tiny buffer to handle any precision shortfall
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 0.01, beFailed: false)

    // Close position
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(6)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed with minimal debt")
}

// =============================================================================
// Test 8: Demonstrate UFix64 precision limits
// =============================================================================
access(all)
fun test_precision_demonstration() {
    log("\n=== UFix64/UFix128 Precision Demonstration ===")

    // Demonstrate UFix64 precision (8 decimal places)
    let value1: UFix64 = 1.00000001
    let value2: UFix64 = 1.00000002
    log("UFix64 minimum precision: 0.00000001")
    log("Value 1: \(value1)")
    log("Value 2: \(value2)")
    log("Difference: \(value2 - value1)")

    // Demonstrate UFix128 intermediate precision
    let uintValue1 = UFix128(1.23456789)
    let uintValue2 = UFix128(9.87654321)
    let product = uintValue1 * uintValue2
    log("\nUFix128 calculation: \(uintValue1) * \(uintValue2) = \(product)")

    // Demonstrate precision loss when converting UFix128 → UFix64
    let rounded = FlowALPMath.toUFix64Round(product)
    let roundedUp = FlowALPMath.toUFix64RoundUp(product)
    let roundedDown = FlowALPMath.toUFix64RoundDown(product)
    log("Converting \(product) to UFix64:")
    log("  Round (nearest): \(rounded)")
    log("  Round Up: \(roundedUp)")
    log("  Round Down: \(roundedDown)")
    log("  Precision loss range: \(roundedUp - roundedDown)")

    log("\n✅ Precision demonstration complete")
    log("Key insight: Each UFix128→UFix64 conversion loses up to 0.00000001")
    log("Multiple operations accumulate this loss, requiring shortfall tolerance")
}

// =============================================================================
// Helper Functions
// =============================================================================

access(all) fun logBalances(_ balances: [FlowALPv0.PositionBalance]) {
    for balance in balances {
        let direction = balance.direction == FlowALPv0.BalanceDirection.Credit ? "Credit" : "Debit"
        log("  \(direction): \(balance.balance) of \(balance.vaultType.identifier)")
    }
}
