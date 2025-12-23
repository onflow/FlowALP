import Test
import BlockchainHelpers

import "MOET"
import "FlowCreditMarket"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all)
fun setup() {
    deployContracts()

    let betaTxResult = grantBeta(protocolAccount, protocolConsumerAccount)

    Test.expect(betaTxResult, Test.beSucceeded())
}

access(all)
fun testAutoBorrowBehaviorWithTargetHealth() {
    // Test that verifies the auto-borrowing behavior when pushToDrawDownSink=true
    // Expected: When depositing 1000 Flow with collateralFactor=0.8 and targetHealth=1.3,
    // the system should automatically borrow ~615.38 MOET
    
    let initialPrice = 1.0
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialPrice)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: initialPrice)

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    
    // Add Flow token support with collateralFactor=0.8
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,  // This means only 80% of Flow value can be used as collateral
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    // Capture MOET balance before opening the position for later comparison (no MOET should be minted)
    let moetVaultBalanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

    // Create position with pushToDrawDownSink=true to trigger auto-rebalancing
    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],  // pushToDrawDownSink=true triggers auto-borrow
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Get position details
    let details = getPositionDetails(pid: 0, beFailed: false)
    
    // Calculate expected auto-borrow amount:
    // Effective collateral = 1000 * 1.0 * 0.8 = 800
    // Target health = 1.3
    // Required effective debt = effective collateral / target health = 800 / 1.3 ≈ 615.38
    let expectedDebt = 800.0 / 1.3  // ≈ 615.38
    
    // Find the MOET balance (which should be debt)
    var moetBalance: UFix64 = 0.0
    var moetDirection: FlowCreditMarket.BalanceDirection? = nil
    for balance in details.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            moetBalance = balance.balance
            moetDirection = balance.direction
        }
    }
    
    // Verify MOET was auto-borrowed
    Test.assert(moetDirection == FlowCreditMarket.BalanceDirection.Debit, 
        message: "Expected MOET to be in Debit (borrowed) state")
    
    // Verify the amount is approximately what we calculated (within 0.01 tolerance)
    Test.assert(moetBalance >= expectedDebt - 0.01 && moetBalance <= expectedDebt + 0.01,
        message: "Expected MOET debt to be approximately \(expectedDebt), but got \(moetBalance)")
    
    // Verify position health is at target
    let health = getPositionHealth(pid: 0, beFailed: false)
    Test.assert(equalWithinVariance(intTargetHealth, health),
        message: "Expected health to be \(intTargetHealth), but got \(health)")

    // Verify the user actually received the borrowed MOET in their Vault (draw-down sink)
    let userMoetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(userMoetBalance >= expectedDebt - 0.01 && userMoetBalance <= expectedDebt + 0.01,
        message: "Expected user MOET Vault balance to be approximately \(expectedDebt), but got \(userMoetBalance)")
}

access(all)
fun testNoAutoBorrowWhenPushToDrawDownSinkFalse() {
    // Test that no auto-borrowing occurs when pushToDrawDownSink=false
    // This validates that users can create positions without automatic leverage
    
    // Note: Pool already exists from previous test, no need to recreate
    let initialPrice = 1.0

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    // Capture MOET balance before opening the position for later comparison (no MOET should be minted)
    let moetVaultBalanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

    // Create position with pushToDrawDownSink=false to prevent auto-rebalancing
    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, false],  // pushToDrawDownSink=false prevents auto-borrow
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Get position details
    let details = getPositionDetails(pid: 1, beFailed: false)
    
    // Verify no MOET was borrowed
    var hasMoetBalance = false
    for balance in details.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            hasMoetBalance = true
            Test.assert(balance.balance == 0.0,
                message: "Expected no MOET balance when pushToDrawDownSink=false")
        }
    }
    
    // Should not have any MOET balance entry
    Test.assert(!hasMoetBalance, 
        message: "Should not have MOET balance when no auto-borrowing occurs")

    // Ensure user's MOET balance remains unchanged (i.e. no tokens minted)
    let moetVaultBalanceAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    Test.assert(moetVaultBalanceAfter == moetVaultBalanceBefore,
        message: "User's MOET Vault balance should remain unchanged when no borrow occurs")
} 
