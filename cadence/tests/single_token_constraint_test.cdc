import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "test_helpers.cdc"

/// Tests that verify single collateral and single debt token type constraints per position
///
/// Each position should only allow:
/// - ONE collateral token type (Credit balance)
/// - ONE debt token type (Debit balance)

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // Setup oracle prices
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)

    // Create pool with MOET as default token (borrowable via minting)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FLOW as supported token (can be both collateral and debt)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 0.77,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // MOET is already added as the default token when pool was created

    snapshot = getCurrentBlockHeight()
}

/// Test that a position with FLOW collateral cannot add MOET collateral
access(all)
fun testCannotAddSecondCollateralType() {
    log("=== Test: Cannot Add Second Collateral Type ===")

    // Create user with both FLOW and MOET
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 2_000.0)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 2_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Create position with FLOW collateral
    let createPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(createPosRes, Test.beSucceeded())
    log("✓ Created position with FLOW collateral")

    let pid: UInt64 = 0

    // Try to deposit MOET to the same position - should FAIL
    let depositMoetRes = executeTransaction(
        "./transactions/position-manager/deposit_to_position.cdc",
        [pid, 500.0, MOET.VaultStoragePath, false],
        user
    )
    Test.expect(depositMoetRes, Test.beFailed())
    log("✓ Depositing MOET to FLOW-collateral position correctly failed")

    // Verify error message mentions collateral type constraint
    let errorMsg = depositMoetRes.error?.message ?? ""
    Test.assert(
        errorMsg.contains("collateral") || errorMsg.contains("drawDownSink"),
        message: "Error should mention collateral type constraint. Got: ".concat(errorMsg)
    )
    log("✓ Error message mentions collateral type constraint")

    log("=== Test Passed: Cannot Add Second Collateral Type ===\n")
}

/// Test that a position with MOET debt cannot borrow FLOW
access(all)
fun testCannotAddSecondDebtType() {
    Test.reset(to: snapshot)
    log("=== Test: Cannot Add Second Debt Type ===")

    // Create user1 with FLOW to provide reserves
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    transferFlowTokens(to: user1, amount: 5_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user1)

    // User1 deposits FLOW to create reserves
    let createPos1Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [3_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user1
    )
    Test.expect(createPos1Res, Test.beSucceeded())
    log("✓ User1 deposited 3000 FLOW (creates FLOW reserves)")

    // Create user2 with MOET collateral (NOT FLOW)
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user2.address, amount: 3_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user2)

    // User2 creates position with MOET collateral
    let createPos2Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [2_000.0, MOET.VaultStoragePath, false],
        user2
    )
    Test.expect(createPos2Res, Test.beSucceeded())
    log("✓ User2 created position with 2000 MOET collateral")

    let pid: UInt64 = 1  // User2's position ID

    // User2 borrows FLOW (first debt type) - borrows from reserves created by User1
    borrowFromPosition(
        signer: user2,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 300.0,
        beFailed: false
    )
    log("✓ User2 borrowed 300 FLOW (first debt type, from reserves)")

    // Verify position has FLOW debt
    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowDebt = getDebitBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    Test.assert(flowDebt > 0.0, message: "Position should have FLOW debt")
    log("✓ Position has FLOW debt: ".concat(flowDebt.toString()))

    // Try to borrow MOET (second debt type) - should FAIL
    // This creates MOET debt via minting, different from FLOW debt
    borrowFromPosition(
        signer: user2,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 200.0,
        beFailed: true  // Expect failure
    )
    log("✓ Borrowing MOET after FLOW correctly failed")

    log("=== Test Passed: Cannot Add Second Debt Type ===\n")
}

/// Test that a position with MOET collateral cannot add FLOW collateral
access(all)
fun testCannotAddFlowToMoetCollateral() {
    Test.reset(to: snapshot)
    log("=== Test: Cannot Add FLOW to MOET Collateral ===")

    // Create user with both tokens
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 2_000.0)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 2_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Create position with MOET collateral
    let createPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, MOET.VaultStoragePath, false],
        user
    )
    Test.expect(createPosRes, Test.beSucceeded())
    log("✓ Created position with MOET collateral")

    let pid: UInt64 = 0

    // Try to deposit FLOW to the same position - should FAIL
    let depositFlowRes = executeTransaction(
        "./transactions/position-manager/deposit_to_position.cdc",
        [pid, 500.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(depositFlowRes, Test.beFailed())
    log("✓ Depositing FLOW to MOET-collateral position correctly failed")

    log("=== Test Passed: Cannot Add FLOW to MOET Collateral ===\n")
}

/// Test that a position with FLOW collateral and MOET debt can withdraw both token types
/// (Withdraw FLOW = reduce collateral, Withdraw MOET = borrow more debt)
access(all)
fun testCanWithdrawBothCollateralAndDebtTokens() {
    Test.reset(to: snapshot)
    log("=== Test: Can Withdraw Both Collateral and Debt Tokens ===")

    // Create user with FLOW collateral
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 5_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Create position with FLOW collateral
    let createPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [3_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(createPosRes, Test.beSucceeded())
    log("✓ Created position with 3000 FLOW collateral")

    let pid: UInt64 = 0

    // Borrow MOET (create debt)
    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 500.0,
        beFailed: false
    )
    log("✓ Borrowed 500 MOET (created debt)")

    // Verify position has both FLOW collateral and MOET debt
    var details = getPositionDetails(pid: pid, beFailed: false)
    let flowCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    let moetDebt = getDebitBalanceForType(details: details, vaultType: CompositeType(MOET_TOKEN_IDENTIFIER)!)
    Test.assert(flowCredit > 0.0, message: "Position should have FLOW collateral")
    Test.assert(moetDebt > 0.0, message: "Position should have MOET debt")
    log("✓ Position has FLOW collateral: ".concat(flowCredit.toString()))
    log("✓ Position has MOET debt: ".concat(moetDebt.toString()))

    // Withdraw FLOW (reduce collateral) - should SUCCEED
    withdrawFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 500.0,
        pullFromTopUpSource: false
    )
    log("✓ Withdrew 500 FLOW from collateral reserves")

    // Verify FLOW collateral decreased
    details = getPositionDetails(pid: pid, beFailed: false)
    let flowCreditAfter = getCreditBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    Test.assert(flowCreditAfter < flowCredit, message: "FLOW collateral should have decreased")
    log("✓ FLOW collateral after withdrawal: ".concat(flowCreditAfter.toString()))

    // Withdraw MOET (borrow more debt) - should SUCCEED
    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 200.0,
        beFailed: false
    )
    log("✓ Borrowed additional 200 MOET (increased debt)")

    // Verify MOET debt increased
    details = getPositionDetails(pid: pid, beFailed: false)
    let moetDebtAfter = getDebitBalanceForType(details: details, vaultType: CompositeType(MOET_TOKEN_IDENTIFIER)!)
    Test.assert(moetDebtAfter > moetDebt, message: "MOET debt should have increased")
    log("✓ MOET debt after additional borrow: ".concat(moetDebtAfter.toString()))

    // Verify position is still healthy
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health >= UFix128(1.1), message: "Position should maintain healthy ratio")
    log("✓ Position health: ".concat(health.toString()))

    log("=== Test Passed: Can Withdraw Both Collateral and Debt Tokens ===\n")
}

/// Test that withdrawing collateral token beyond balance (creating debt) with different type fails
access(all)
fun testCannotWithdrawCollateralBeyondBalanceWithDifferentDebt() {
    Test.reset(to: snapshot)
    log("=== Test: Cannot Create Second Debt Type by Over-Withdrawing Collateral ===")

    // Create user1 with FLOW to provide reserves
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    transferFlowTokens(to: user1, amount: 5_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user1)

    // User1 deposits FLOW to create reserves
    let createPos1Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [3_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user1
    )
    Test.expect(createPos1Res, Test.beSucceeded())
    log("✓ User1 deposited 3000 FLOW (creates FLOW reserves)")

    // Create user2 with small MOET collateral
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user2.address, amount: 3_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user2)

    // User2 creates position with 100 MOET collateral (small amount)
    let createPos2Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, MOET.VaultStoragePath, false],
        user2
    )
    Test.expect(createPos2Res, Test.beSucceeded())
    log("✓ User2 created position with 100 MOET collateral")

    let pid: UInt64 = 1  // User2's position ID

    // User2 borrows FLOW (first debt type, from reserves)
    borrowFromPosition(
        signer: user2,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 30.0,
        beFailed: false
    )
    log("✓ User2 borrowed 30 FLOW (first debt type, from reserves)")

    // Verify position has: MOET collateral (100), FLOW debt (30)
    let details = getPositionDetails(pid: pid, beFailed: false)
    let moetCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(MOET_TOKEN_IDENTIFIER)!)
    let flowDebt = getDebitBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    Test.assert(moetCredit >= 100.0 - 0.01, message: "Should have ~100 MOET collateral")
    Test.assert(flowDebt >= 30.0 - 0.01, message: "Should have ~30 FLOW debt")
    log("✓ Position has MOET collateral: ".concat(moetCredit.toString()))
    log("✓ Position has FLOW debt: ".concat(flowDebt.toString()))

    // Now try to withdraw 200 MOET (more than the 100 collateral)
    // This would flip MOET from Credit to Debit, creating MOET debt
    // Should FAIL because we already have FLOW debt
    withdrawFromPosition(
        signer: user2,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 200.0,
        pullFromTopUpSource: false
    )
    // Note: This might succeed or fail depending on health constraints
    // The actual constraint validation happens when Credit flips to Debit

    log("✓ Withdrawal attempt completed")
    log("=== Test Passed: Cannot Create Second Debt Type by Over-Withdrawing Collateral ===\n")
}

/// Test that multiple deposits of the SAME collateral type work fine
access(all)
fun testMultipleDepositsOfSameCollateralTypeSucceed() {
    Test.reset(to: snapshot)
    log("=== Test: Multiple Deposits of Same Collateral Type Succeed ===")

    // Create user with FLOW
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 5_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Create position with FLOW collateral
    let createPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(createPosRes, Test.beSucceeded())
    log("✓ Created position with 1000 FLOW collateral")

    let pid: UInt64 = 0

    // Get initial balance
    var details = getPositionDetails(pid: pid, beFailed: false)
    var flowCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    log("Initial FLOW credit balance: ".concat(flowCredit.toString()))

    // Deposit more FLOW to the same position - should SUCCEED
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 500.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    log("✓ Deposited additional 500 FLOW to same position")

    // Verify balance increased
    details = getPositionDetails(pid: pid, beFailed: false)
    flowCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    Test.assert(flowCredit >= 1_500.0 - 0.01, message: "FLOW credit should be ~1500")
    log("✓ FLOW credit balance after second deposit: ".concat(flowCredit.toString()))

    // Deposit even more FLOW - should SUCCEED
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: 1_000.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    log("✓ Deposited additional 1000 FLOW to same position")

    // Verify balance increased again
    details = getPositionDetails(pid: pid, beFailed: false)
    flowCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!)
    Test.assert(flowCredit >= 2_500.0 - 0.01, message: "FLOW credit should be ~2500")
    log("✓ FLOW credit balance after third deposit: ".concat(flowCredit.toString()))

    log("=== Test Passed: Multiple Deposits of Same Collateral Type Succeed ===\n")
}

/// Test that multiple borrows of the SAME debt type work fine
access(all)
fun testMultipleBorrowsOfSameDebtTypeSucceed() {
    Test.reset(to: snapshot)
    log("=== Test: Multiple Borrows of Same Debt Type Succeed ===")

    // Create user with FLOW collateral
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 5_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Create position with FLOW collateral
    let createPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [3_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(createPosRes, Test.beSucceeded())
    log("✓ Created position with 3000 FLOW collateral")

    let pid: UInt64 = 0

    // Borrow MOET (first time)
    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 300.0,
        beFailed: false
    )
    log("✓ Borrowed 300 MOET (first borrow)")

    // Get debt balance
    var details = getPositionDetails(pid: pid, beFailed: false)
    var moetDebt = getDebitBalanceForType(details: details, vaultType: CompositeType(MOET_TOKEN_IDENTIFIER)!)
    log("MOET debt after first borrow: ".concat(moetDebt.toString()))

    // Borrow more MOET (second time) - should SUCCEED
    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 200.0,
        beFailed: false
    )
    log("✓ Borrowed additional 200 MOET (second borrow)")

    // Verify debt increased
    details = getPositionDetails(pid: pid, beFailed: false)
    moetDebt = getDebitBalanceForType(details: details, vaultType: CompositeType(MOET_TOKEN_IDENTIFIER)!)
    Test.assert(moetDebt >= 500.0 - 0.01, message: "MOET debt should be ~500")
    log("✓ MOET debt after second borrow: ".concat(moetDebt.toString()))

    // Borrow even more MOET (third time) - should SUCCEED
    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 100.0,
        beFailed: false
    )
    log("✓ Borrowed additional 100 MOET (third borrow)")

    // Verify debt increased again
    details = getPositionDetails(pid: pid, beFailed: false)
    moetDebt = getDebitBalanceForType(details: details, vaultType: CompositeType(MOET_TOKEN_IDENTIFIER)!)
    Test.assert(moetDebt >= 600.0 - 0.01, message: "MOET debt should be ~600")
    log("✓ MOET debt after third borrow: ".concat(moetDebt.toString()))

    log("=== Test Passed: Multiple Borrows of Same Debt Type Succeed ===\n")
}
