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
// Test 3: Close with precision shortfall after multiple rebalances
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
    let reb1 = _executeTransaction("../transactions/flow-alp/pool-management/rebalance_position.cdc", [UInt64(2), true], PROTOCOL_ACCOUNT)
    Test.expect(reb1, Test.beSucceeded())

    log("\nRebalance 2: FLOW price = $1.9")
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 0.9)
    let reb2 = _executeTransaction("../transactions/flow-alp/pool-management/rebalance_position.cdc", [UInt64(2), true], PROTOCOL_ACCOUNT)
    Test.expect(reb2, Test.beSucceeded())

    log("\nRebalance 3: FLOW price = $1.5")
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.5)
    let reb3 = _executeTransaction("../transactions/flow-alp/pool-management/rebalance_position.cdc", [UInt64(2), true], PROTOCOL_ACCOUNT)
    Test.expect(reb3, Test.beSucceeded())

    // Get final position state
    let finalDetails = getPositionDetails(pid: 2, beFailed: false)
    log("\n--- Final State ---")
    log("Health: \(finalDetails.health)")
    logBalances(finalDetails.balances)

    // Close position - may have tiny shortfall due to accumulated rounding
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(2)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed after 3 rebalances (precision shortfall automatically handled)")
}

// =============================================================================
// Test 4: Demonstrate precision with extreme volatility
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
            [UInt64(3), true],
            PROTOCOL_ACCOUNT
        )
        Test.expect(rebalanceRes, Test.beSucceeded())

        let details = getPositionDetails(pid: 3, beFailed: false)
        log("Health: \(details.health)")
        volCount = volCount + 1
    }

    log("\n--- Closing after extreme volatility ---")

    // Close position
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(3)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    log("✅ Successfully closed after extreme volatility (balance increased/fell dramatically)")
}

// =============================================================================
// Test 5: Close position with insufficient debt repayment
// =============================================================================
access(all)
fun test_closePosition_insufficientRepayment() {
    log("\n=== Test: Close Position with Insufficient Debt Repayment ===")

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position with debt — borrowed MOET is pushed to user's MOET vault (position 7)
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let debt = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    log("Borrowed MOET (= debt): \(debt)")
    Test.assert(debt > 0.0)

    let shortfall = 0.00000001

    // Transfer a tiny amount away so user has (debt - 1 satoshi), one short of what's needed
    let other = Test.createAccount()
    setupMoetVault(other, beFailed: false)
    let transferTx = Test.Transaction(
        code: Test.readFile("../transactions/moet/transfer_moet.cdc"),
        authorizers: [user.address],
        signers: [user],
        arguments: [other.address, shortfall]
    )
    let transferRes = Test.executeTransaction(transferTx)
    Test.expect(transferRes, Test.beSucceeded())

    let remainingMoet = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    log("MOET remaining after transfer: \(remainingMoet)")
    Test.assertEqual(debt - shortfall, remainingMoet)

    // Attempt to close — source has 0 MOET but debt requires repayment
    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(4)],
        user
    )
    Test.expect(closeRes, Test.beFailed())
    Test.assertError(closeRes, errorMessage: "Insufficient funds from source")
    log("✅ Close correctly failed with insufficient repayment")
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
