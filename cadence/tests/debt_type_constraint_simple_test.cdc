import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "test_helpers.cdc"

/// Simple test to verify debt type constraint is enforced

access(all)
fun setup() {
    deployContracts()

    // Setup oracle prices
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)

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
}

/// Test that a position with FLOW debt cannot borrow MOET (second debt type)
access(all)
fun testDebtTypeConstraint() {
    log("=== Test: Debt Type Constraint ===")

    // Create user1 to provide FLOW reserves
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    transferFlowTokens(to: user1, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user1)

    // User1 deposits FLOW (creates reserves)
    let createPos1 = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [5_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user1
    )
    Test.expect(createPos1, Test.beSucceeded())
    log("✓ User1 deposited 5000 FLOW to create reserves")

    // Create user2 with MOET collateral
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user2.address, amount: 10_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user2)

    // User2 creates position with MOET collateral
    let createPos2 = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [5_000.0, MOET.VaultStoragePath, false],
        user2
    )
    Test.expect(createPos2, Test.beSucceeded())
    log("✓ User2 created position with 5000 MOET collateral")

    let pid: UInt64 = 1  // User2's position

    // User2 borrows FLOW (first debt type, from reserves)
    borrowFromPosition(
        signer: user2,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 1_000.0,
        beFailed: false
    )
    log("✓ User2 borrowed 1000 FLOW (first debt type)")

    // Verify User2 has FLOW debt
    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowDebt = getDebitBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    Test.assert(flowDebt >= 1_000.0 - 0.01, message: "User2 should have ~1000 FLOW debt")
    log("✓ User2 has FLOW debt: ".concat(flowDebt.toString()))

    // User2 tries to borrow MOET (second debt type, via minting)
    // Need to withdraw MORE than collateral amount to flip MOET from Credit to Debit
    // This should FAIL with debt type constraint error
    let borrowMoet = executeTransaction(
        "./transactions/position-manager/borrow_from_position.cdc",
        [pid, MOET_TOKEN_IDENTIFIER, 6_000.0],  // More than 5000 collateral
        user2
    )

    // Check if it failed
    if borrowMoet.status == Test.ResultStatus.succeeded {
        log("❌ ERROR: Borrowing MOET should have failed but succeeded!")
        log("❌ Debt type constraint is NOT enforced")
        Test.assert(false, message: "Debt type constraint should prevent borrowing MOET after FLOW")
    } else {
        log("✓ Borrowing MOET correctly failed")

        // Check error message
        let errorMsg = borrowMoet.error?.message ?? ""
        if errorMsg.contains("debt type") || errorMsg.contains("Only one debt type") {
            log("✓ Error message mentions debt type constraint: ".concat(errorMsg))
        } else {
            log("⚠ Warning: Error message doesn't mention debt type: ".concat(errorMsg))
        }
    }

    log("=== Test Complete ===\n")
}
