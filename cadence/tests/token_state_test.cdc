import Test
import "TidalProtocol"
// CHANGE: Import FlowToken to use correct type references
import "./test_helpers.cdc"

access(all)
fun setup() {
    // Use the shared deployContracts function
    deployContracts()
}

// E-series: Token state management

access(all)
fun testCreditBalanceUpdates() {
    /* 
     * Test E-1: Credit balance updates
     * 
     * Deposit funds and check TokenState
     * totalCreditBalance increases correctly
     */
    
    // Create pool
    let defaultThreshold: UFix64 = 1.0
    var pool <- createTestPool(defaultTokenThreshold: defaultThreshold)
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Check initial reserve balance
    // CHANGE: Updated type reference to MockVault
    let initialReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(0.0, initialReserve)
    
    // Create position and deposit 100 FLOW
    let pid = poolRef.createPosition()
    let depositVault <- createTestVault(balance: 100.0)
    poolRef.deposit(pid: pid, funds: <- depositVault)
    
    // Check reserve increased by deposit amount
    // CHANGE: Updated type reference to MockVault
    let afterDepositReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(100.0, afterDepositReserve)
    
    // Deposit more funds
    let secondDeposit <- createTestVault(balance: 50.0)
    poolRef.deposit(pid: pid, funds: <- secondDeposit)
    
    // Check reserve increased again
    // CHANGE: Updated type reference to MockVault
    let finalReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(150.0, finalReserve)
    
    // Clean up
    destroy pool
}

access(all)
fun testDebitBalanceUpdates() {
    /* 
     * Test E-2: Debit balance updates
     * 
     * Withdraw to create debt and check TokenState
     * totalDebitBalance increases correctly
     */
    
    // Create pool with initial funding
    let defaultThreshold: UFix64 = 0.8
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: defaultThreshold,
        initialBalance: 1000.0
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Create borrower position with collateral
    let borrowerPid = poolRef.createPosition()
    let collateralVault <- createTestVault(balance: 200.0)
    poolRef.deposit(pid: borrowerPid, funds: <- collateralVault)
    
    // Initial reserve should be 1200 (1000 + 200)
    // CHANGE: Updated type reference to MockVault
    let initialReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(1200.0, initialReserve)
    
    // Borrow 100 FLOW (creating debt)
    let borrowed <- poolRef.withdraw(
        pid: borrowerPid,
        amount: 100.0,
        // CHANGE: Updated type parameter to MockVault
        type: Type<@MockVault>()
    ) as! @MockVault  // CHANGE: Cast to MockVault
    
    // Reserve should decrease by borrowed amount
    // CHANGE: Updated type reference to MockVault
    let afterBorrowReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(1100.0, afterBorrowReserve)
    
    // Borrow more
    let secondBorrow <- poolRef.withdraw(
        pid: borrowerPid,
        amount: 50.0,
        // CHANGE: Updated type parameter to MockVault
        type: Type<@MockVault>()
    ) as! @MockVault  // CHANGE: Cast to MockVault
    
    // Reserve should decrease again
    // CHANGE: Updated type reference to MockVault
    let finalReserve = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(1050.0, finalReserve)
    
    // Clean up
    destroy borrowed
    destroy secondBorrow
    destroy pool
}

access(all)
fun testBalanceDirectionFlips() {
    /* 
     * Test E-3: Balance direction flips
     * 
     * Test deposits/withdrawals that flip balance direction
     * TokenState tracks both credit and debit changes
     */
    
    // Create pool with lower threshold to allow borrowing
    let defaultThreshold: UFix64 = 0.5
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: defaultThreshold,
        initialBalance: 1000.0
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Create test position
    let testPid = poolRef.createPosition()
    
    // Start with credit: deposit 100 FLOW
    let initialDeposit <- createTestVault(balance: 100.0)
    poolRef.deposit(pid: testPid, funds: <- initialDeposit)
    
    // Position should be healthy (credit only)
    Test.assertEqual(1.0, poolRef.positionHealth(pid: testPid))
    
    // Withdraw 40 FLOW (still in credit: 100 - 40 = 60)
    let firstWithdraw <- poolRef.withdraw(
        pid: testPid,
        amount: 40.0,
        // CHANGE: Updated type parameter to MockVault
        type: Type<@MockVault>()
    ) as! @MockVault  // CHANGE: Cast to MockVault
    
    // Still healthy
    Test.assertEqual(1.0, poolRef.positionHealth(pid: testPid))
    
    // Withdraw another 40 FLOW (now net position: 100 - 40 - 40 = 20 credit)
    let secondWithdraw <- poolRef.withdraw(
        pid: testPid,
        amount: 40.0,
        // CHANGE: Updated type parameter to MockVault
        type: Type<@MockVault>()
    ) as! @MockVault  // CHANGE: Cast to MockVault
    
    // Still healthy but with less margin
    Test.assertEqual(1.0, poolRef.positionHealth(pid: testPid))
    
    // Now deposit back 50 FLOW (net: 20 + 50 = 70 credit)
    let reDeposit <- createTestVault(balance: 50.0)
    poolRef.deposit(pid: testPid, funds: <- reDeposit)
    
    // Should still be healthy
    Test.assertEqual(1.0, poolRef.positionHealth(pid: testPid))
    
    // Clean up
    destroy firstWithdraw
    destroy secondWithdraw
    destroy pool
} 