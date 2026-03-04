import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "DummyToken"
import "FlowALPv0"
import "test_helpers.cdc"

/// Three-token test to properly verify debt type constraint enforcement
/// Uses DummyToken, FLOW, and MOET to test that a position cannot have multiple debt types

access(all) let DUMMY_TOKEN_IDENTIFIER = "A.0000000000000007.DummyToken.Vault"

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // Setup oracle prices for all three tokens
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: DUMMY_TOKEN_IDENTIFIER, price: 1.0)

    // Create pool with MOET as default token
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FLOW as supported token
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 0.77,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Add DummyToken as supported token
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: DUMMY_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 0.77,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
}

/// Test that a position with DummyToken collateral and FLOW debt cannot borrow MOET (second debt type)
access(all)
fun testCannotBorrowSecondDebtType() {
    log("=== Test: Cannot Borrow Second Debt Type (3 Tokens) ===\n")

    // ===== Setup: Create reserves for FLOW and MOET =====

    // User to provide FLOW reserves
    let flowProvider = Test.createAccount()
    setupMoetVault(flowProvider, beFailed: false)
    transferFlowTokens(to: flowProvider, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, flowProvider)

    let createFlowPos = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [5_000.0, FLOW_VAULT_STORAGE_PATH, false],
        flowProvider
    )
    Test.expect(createFlowPos, Test.beSucceeded())
    log("✓ FlowProvider deposited 5000 FLOW (creates FLOW reserves)")

    // ===== Main Test User =====

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    setupDummyTokenVault(user)
    mintDummyToken(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    log("✓ User created with DummyToken")

    // User creates position with DummyToken collateral
    let createPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [5_000.0, DummyToken.VaultStoragePath, false],
        user
    )
    Test.expect(createPosRes, Test.beSucceeded())
    log("✓ User created position with 5000 DummyToken collateral\n")

    let pid: UInt64 = 1  // User's position ID

    // Verify position has DummyToken collateral
    var details = getPositionDetails(pid: pid, beFailed: false)
    let dummyCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(DUMMY_TOKEN_IDENTIFIER)!)
    Test.assert(dummyCredit >= 5_000.0 - 0.01, message: "Position should have ~5000 DummyToken collateral")
    log("Position state:")
    log("  - DummyToken collateral: ".concat(dummyCredit.toString()))

    // ===== Step 1: Borrow FLOW (first debt type) =====

    log("\n--- Step 1: Borrow FLOW (first debt type) ---")

    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 1_000.0,
        beFailed: false
    )
    log("✓ User borrowed 1000 FLOW (first debt type, from reserves)")

    // Verify position now has FLOW debt
    details = getPositionDetails(pid: pid, beFailed: false)
    let flowDebt = getDebitBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    Test.assert(flowDebt >= 1_000.0 - 0.01, message: "Position should have ~1000 FLOW debt")

    log("\nPosition state after borrowing FLOW:")
    log("  - DummyToken collateral: ".concat(dummyCredit.toString()))
    log("  - FLOW debt: ".concat(flowDebt.toString()))

    // Check position health
    let health = getPositionHealth(pid: pid, beFailed: false)
    log("  - Health: ".concat(health.toString()))
    Test.assert(health >= UFix128(1.1), message: "Position should be healthy")

    // ===== Step 2: Try to borrow MOET (second debt type) - SHOULD FAIL =====

    log("\n--- Step 2: Try to borrow MOET (second debt type) ---")

    let borrowMoetRes = executeTransaction(
        "./transactions/position-manager/borrow_from_position.cdc",
        [pid, MOET_TOKEN_IDENTIFIER, 500.0],
        user
    )

    Test.expect(borrowMoetRes, Test.beFailed())
    Test.assertError(borrowMoetRes, errorMessage: "debt type")

    log("\n=== Test Complete: Debt Type Constraint Verified ===")
}

// Helper functions

access(all)
fun setupDummyTokenVault(_ account: Test.TestAccount) {
    let result = executeTransaction(
        "./transactions/dummy_token/setup_vault.cdc",
        [],
        account
    )
    Test.expect(result, Test.beSucceeded())
}

access(all)
fun mintDummyToken(to: Test.TestAccount, amount: UFix64) {
    let result = executeTransaction(
        "./transactions/dummy_token/mint.cdc",
        [amount, to.address],
        PROTOCOL_ACCOUNT
    )
    Test.expect(result, Test.beSucceeded())
}
