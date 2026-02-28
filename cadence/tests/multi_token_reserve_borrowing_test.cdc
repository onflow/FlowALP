import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "DummyToken"
import "FlowALPv0"
import "test_helpers.cdc"

access(all)
fun setup() {
    deployContracts()
    // DummyToken is now configured in flow.json and deployed automatically
}

/// Tests reserve-based borrowing with distinct token types
/// Scenario:
/// 1. User1: deposits FLOW collateral → borrows MOET
/// 2. User2: deposits MOET collateral → borrows FLOW (from User1's reserves)
/// 3. User2: repays FLOW debt → withdraws MOET
/// 4. User1: repays MOET debt → withdraws FLOW
access(all)
fun testMultiTokenReserveBorrowing() {
    log("=== Starting Multi-Token Reserve Borrowing Test ===")

    // Setup oracle prices
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)
    log("✓ Oracle prices set: FLOW=$1, MOET=$1")

    // Create pool with MOET as default token (borrowable via minting)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    log("✓ Pool created with MOET as default token")

    // Add FLOW as supported token (can be both collateral and debt)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 0.77,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    log("✓ FLOW added as supported token (CF=0.8, BF=0.77)")

    // Note: MOET is already added as the default/mintable token when pool was created
    // It can be used as both collateral and debt

    // ===== USER 1: Deposit FLOW collateral, borrow MOET =====
    log("")
    log("--- User 1: Deposit FLOW, Borrow MOET ---")

    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    mintFlow(to: user1, amount: 2_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user1)

    let user1InitialFlow = getBalance(address: user1.address, vaultPublicPath: /public/flowTokenReceiver)!
    let user1InitialMoet = getBalance(address: user1.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("User1 initial - FLOW: ".concat(user1InitialFlow.toString()).concat(", MOET: ").concat(user1InitialMoet.toString()))

    // User1 deposits 1000 FLOW as collateral (no auto-borrow)
    let createPos1Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user1
    )
    Test.expect(createPos1Res, Test.beSucceeded())
    log("✓ User1 deposited 1000 FLOW as collateral")

    let pid1: UInt64 = 0

    // User1 borrows MOET (via minting)
    // Effective collateral = 1000 FLOW * $1 * 0.8 = $800
    // Can borrow up to $800 * 0.77 = $616
    let user1MoetBorrowAmount = 400.0
    borrowFromPosition(
        signer: user1,
        positionId: pid1,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: user1MoetBorrowAmount,
        beFailed: false
    )
    log("✓ User1 borrowed ".concat(user1MoetBorrowAmount.toString()).concat(" MOET (via minting)"))

    let user1MoetBalance = getBalance(address: user1.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(user1MoetBalance >= user1MoetBorrowAmount - 0.01,
                message: "User1 should have ~".concat(user1MoetBorrowAmount.toString()).concat(" MOET"))
    log("✓ User1 now has ".concat(user1MoetBalance.toString()).concat(" MOET"))

    // Check User1 position health
    var health1 = getPositionHealth(pid: pid1, beFailed: false)
    log("User1 position health: ".concat(health1.toString()))
    // Expected: 800 / 400 = 2.0
    Test.assert(health1 >= UFix128(1.99) && health1 <= UFix128(2.01),
                message: "Expected User1 health ~2.0")

    // Now User1's FLOW collateral is in the pool and can be borrowed by others!
    log("✓ User1's 1000 FLOW is now in the pool as reserves")

    // ===== USER 2: Deposit MOET collateral, borrow FLOW =====
    log("")
    log("--- User 2: Deposit MOET, Borrow FLOW (from reserves) ---")

    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user2)

    // Mint 1000 MOET to user2 (worth $1000 at $1 each)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user2.address, amount: 1000.0, beFailed: false)

    let user2InitialFlow = getBalance(address: user2.address, vaultPublicPath: /public/flowTokenReceiver)!
    let user2InitialMoet = getBalance(address: user2.address, vaultPublicPath: MOET.VaultPublicPath)!
    log("User2 initial - FLOW: ".concat(user2InitialFlow.toString()).concat(", MOET: ").concat(user2InitialMoet.toString()))

    // User2 deposits 1000 MOET as collateral
    let createPos2Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1000.0, MOET.VaultStoragePath, false],
        user2
    )
    Test.expect(createPos2Res, Test.beSucceeded())
    log("✓ User2 deposited 1000 MOET as collateral")

    let pid2: UInt64 = 1

    // User2 borrows FLOW (via reserves - from User1's collateral!)
    // Effective collateral = 1000 MOET * $1 * 0.8 = $800
    // Can borrow up to $800 * 0.77 = $616
    let user2FlowBorrowAmount = 300.0
    borrowFromPosition(
        signer: user2,
        positionId: pid2,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: user2FlowBorrowAmount,
        beFailed: false
    )
    log("✓ User2 borrowed ".concat(user2FlowBorrowAmount.toString()).concat(" FLOW (via reserves from User1's collateral!)"))

    let user2FlowBalance = getBalance(address: user2.address, vaultPublicPath: /public/flowTokenReceiver)!
    let user2FlowReceived = user2FlowBalance - user2InitialFlow
    Test.assert(user2FlowReceived >= user2FlowBorrowAmount - 0.01,
                message: "User2 should have received ~".concat(user2FlowBorrowAmount.toString()).concat(" FLOW"))
    log("✓ User2 now has ".concat(user2FlowReceived.toString()).concat(" FLOW borrowed from reserves"))

    // Check User2 position health
    var health2 = getPositionHealth(pid: pid2, beFailed: false)
    log("User2 position health: ".concat(health2.toString()))
    // Health = 1000 MOET CF / (300 FLOW / BF) ≈ 2.567
    Test.assert(health2 >= UFix128(2.5) && health2 <= UFix128(2.6),
                message: "Expected User2 health ~2.567")

    log("")
    log("✓ Both positions active:")
    log("  - User1 (pid=0): 1000 FLOW collateral, 400 MOET debt")
    log("  - User2 (pid=1): 1000 MOET collateral, 300 FLOW debt")

    // ===== USER 2: Repay FLOW debt, withdraw MOET =====
    log("")
    log("--- User 2: Repay FLOW, Withdraw MOET ---")

    // User2 repays FLOW debt (borrowed from reserves)
    depositToPosition(
        signer: user2,
        positionID: pid2,
        amount: user2FlowBorrowAmount,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    log("✓ User2 repaid ".concat(user2FlowBorrowAmount.toString()).concat(" FLOW debt"))

    // Check User2 health after repayment (should be very high - no debt)
    health2 = getPositionHealth(pid: pid2, beFailed: false)
    log("User2 health after repayment: ".concat(health2.toString()))
    Test.assert(health2 > UFix128(100.0), message: "Expected very high health after repayment")

    // User2 withdraws MOET collateral
    withdrawFromPosition(
        signer: user2,
        positionId: pid2,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: user2InitialMoet,
        pullFromTopUpSource: false
    )
    log("✓ User2 withdrew ".concat(user2InitialMoet.toString()).concat(" MOET collateral"))

    // Verify User2 got their MOET back
    let user2FinalMoet = getBalance(address: user2.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(user2FinalMoet >= user2InitialMoet - 0.01,
                message: "User2 should get back ~".concat(user2InitialMoet.toString()).concat(" MOET"))
    log("✓ User2 received back ".concat(user2FinalMoet.toString()).concat(" MOET tokens"))

    // ===== USER 1: Repay MOET debt, withdraw FLOW =====
    log("")
    log("--- User 1: Repay MOET, Withdraw FLOW ---")

    // User1 repays MOET debt
    depositToPosition(
        signer: user1,
        positionID: pid1,
        amount: user1MoetBorrowAmount,
        vaultStoragePath: MOET.VaultStoragePath,
        pushToDrawDownSink: false
    )
    log("✓ User1 repaid ".concat(user1MoetBorrowAmount.toString()).concat(" MOET debt"))

    // Check User1 health after repayment
    health1 = getPositionHealth(pid: pid1, beFailed: false)
    log("User1 health after repayment: ".concat(health1.toString()))
    Test.assert(health1 > UFix128(100.0), message: "Expected very high health after repayment")

    // User1 withdraws FLOW collateral
    withdrawFromPosition(
        signer: user1,
        positionId: pid1,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 1_000.0,
        pullFromTopUpSource: false
    )
    log("✓ User1 withdrew 1000 FLOW collateral")

    // Verify User1 got their FLOW back
    let user1FinalFlow = getBalance(address: user1.address, vaultPublicPath: /public/flowTokenReceiver)!
    // User1 should have close to their initial balance back
    Test.assert(user1FinalFlow >= user1InitialFlow - 1.0,
                message: "User1 should get back approximately their initial FLOW")
    log("✓ User1 received back ".concat(user1FinalFlow.toString()).concat(" FLOW"))

    log("")
    log("=== Multi-Token Reserve Borrowing Test Complete ===")
    log("")
    log("Summary:")
    log("  ✓ User1 deposited FLOW, borrowed MOET (via minting)")
    log("  ✓ User2 deposited MOET, borrowed FLOW (via reserves from User1)")
    log("  ✓ User2 repaid FLOW, withdrew MOET")
    log("  ✓ User1 repaid MOET, withdrew FLOW")
    log("  ✓ Reserve-based borrowing works across distinct token types!")
}

// Helper function to setup DummyToken vault
access(all)
fun setupDummyTokenVault(_ account: Test.TestAccount) {
    let result = executeTransaction(
        "./transactions/dummy_token/setup_vault.cdc",
        [],
        account
    )
    Test.expect(result, Test.beSucceeded())
}

// Helper function to mint DummyToken
access(all)
fun mintDummyToken(to: Test.TestAccount, amount: UFix64) {
    let result = executeTransaction(
        "./transactions/dummy_token/mint.cdc",
        [amount, to.address],
        PROTOCOL_ACCOUNT
    )
    Test.expect(result, Test.beSucceeded())
}
