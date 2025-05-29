import Test
import "TidalProtocol"
// CHANGE: Import FlowToken to use correct type references
import "./test_helpers.cdc"

access(all)
fun setup() {
    // Use the shared deployContracts function
    deployContracts()
}

// F-series: Reserve management

access(all)
fun testReserveBalanceTracking() {
    /* 
     * Test F-1: Reserve balance tracking
     * 
     * Deposit and withdraw from pool
     * reserveBalance() matches expected amounts
     */
    
    // Create pool
    let defaultThreshold: UFix64 = 1.0
    var pool <- createTestPool(defaultTokenThreshold: defaultThreshold)
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Initial reserve should be 0
    // CHANGE: Updated type reference to MockVault
    let initialReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(0.0, initialReserve)
    
    // Create multiple positions and deposit
    let pid1 = poolRef.createPosition()
    let deposit1 <- createTestVault(balance: 100.0)
    poolRef.deposit(pid: pid1, funds: <- deposit1)
    
    let pid2 = poolRef.createPosition()
    let deposit2 <- createTestVault(balance: 200.0)
    poolRef.deposit(pid: pid2, funds: <- deposit2)
    
    // Total reserve should be 300
    // CHANGE: Updated type reference to MockVault
    let afterDepositsReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(300.0, afterDepositsReserve)
    
    // Withdraw from first position
    let withdrawn <- poolRef.withdraw(
        pid: pid1,
        amount: 50.0,
        // CHANGE: Updated type parameter to MockVault
        type: Type<@MockVault>()
    ) as! @MockVault  // CHANGE: Cast to MockVault
    
    // Reserve should decrease
    // CHANGE: Updated type reference to MockVault
    let afterWithdrawReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(250.0, afterWithdrawReserve)
    
    // Clean up
    destroy withdrawn
    destroy pool
}

access(all)
fun testMultiplePositions() {
    /* 
     * Test F-2: Multiple positions
     * 
     * Create multiple positions in same pool
     * Each position tracked independently
     */
    
    // Create pool with funding
    let defaultThreshold: UFix64 = 0.8
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: defaultThreshold,
        initialBalance: 1000.0
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Create three different positions
    let positions: [UInt64] = []
    positions.append(poolRef.createPosition())
    positions.append(poolRef.createPosition())
    positions.append(poolRef.createPosition())
    
    // Deposit different amounts in each position
    let amounts: [UFix64] = [100.0, 200.0, 300.0]
    var i = 0
    for pid in positions {
        let deposit <- createTestVault(balance: amounts[i])
        poolRef.deposit(pid: pid, funds: <- deposit)
        i = i + 1
    }
    
    // Each position should have independent health
    for pid in positions {
        let health = poolRef.positionHealth(pid: pid)
        Test.assertEqual(1.0, health)
    }
    
    // Borrow from middle position only
    let borrowed <- poolRef.withdraw(
        pid: positions[1],
        amount: 100.0,
        // CHANGE: Updated type parameter to MockVault
        type: Type<@MockVault>()
    ) as! @MockVault  // CHANGE: Cast to MockVault
    
    // All positions should still have health of 1.0
    // Position 1 has 200 deposit - 100 borrowed = 100 net credit (no debt)
    Test.assertEqual(1.0, poolRef.positionHealth(pid: positions[0]))
    Test.assertEqual(1.0, poolRef.positionHealth(pid: positions[1]))
    Test.assertEqual(1.0, poolRef.positionHealth(pid: positions[2]))
    
    // Clean up
    destroy borrowed
    destroy pool
}

access(all)
fun testPositionIDGeneration() {
    /* 
     * Test F-3: Position ID generation
     * 
     * Create multiple positions
     * IDs increment sequentially from 0
     */
    
    // Create pool
    let defaultThreshold: UFix64 = 1.0
    var pool <- createTestPool(defaultTokenThreshold: defaultThreshold)
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Create positions and verify sequential IDs
    let expectedIDs: [UInt64] = [0, 1, 2, 3, 4]
    let actualIDs: [UInt64] = []
    
    for _ in expectedIDs {
        let pid = poolRef.createPosition()
        actualIDs.append(pid)
    }
    
    // Verify IDs match expected sequence
    var index = 0
    for expectedID in expectedIDs {
        Test.assertEqual(expectedID, actualIDs[index])
        index = index + 1
    }
    
    // Clean up
    destroy pool
} 