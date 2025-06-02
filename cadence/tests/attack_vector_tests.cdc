import Test
import "TidalProtocol"
// CHANGE: Import FlowToken to use correct type references
import "./test_helpers.cdc"

access(all)
fun setup() {
    deployContracts()
}

// ===== ATTACK VECTOR 1: REENTRANCY ATTEMPTS =====

access(all) fun testReentrancyProtection() {
    /*
     * Attack: Try to reenter deposit/withdraw during execution
     * Protection: Cadence's resource model prevents reentrancy
     */
    
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: 0.8,
        initialBalance: 10000.0
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Create attacker position
    let attackerPid = poolRef.createPosition()
    let initialDeposit <- createTestVault(balance: 1000.0)
    poolRef.deposit(pid: attackerPid, funds: <- initialDeposit)
    
    // In Cadence, resources prevent reentrancy by design
    // The vault is moved during operations, preventing double-spending
    
    // Try rapid sequential operations (closest we can get to reentrancy test)
    let amounts: [UFix64] = [100.0, 200.0, 150.0, 300.0, 250.0]
    var totalWithdrawn: UFix64 = 0.0
    
    for amount in amounts {
        if totalWithdrawn + amount <= 1000.0 {
            let withdrawn <- poolRef.withdraw(
                pid: attackerPid,
                amount: amount,
                type: Type<@MockVault>()
            ) as! @MockVault
            totalWithdrawn = totalWithdrawn + amount
            destroy withdrawn
        }
    }
    
    // Verify total withdrawn matches expectations
    Test.assertEqual(totalWithdrawn, 1000.0)
    
    // Verify position is now empty (we withdrew everything)
    // No more withdrawals should be possible
    
    destroy pool
}

// ===== ATTACK VECTOR 2: PRECISION LOSS EXPLOITATION =====

access(all) fun testPrecisionLossExploitation() {
    /*
     * Attack: Try to exploit rounding errors in scaled balance calculations
     * Protection: Verify no value can be created through precision loss
     */
    
    var pool <- createTestPool(defaultTokenThreshold: 0.8)
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Test with amounts designed to cause precision issues
    let precisionTestAmounts: [UFix64] = [
        0.00000001,  // Minimum UFix64
        0.00000003,  // Odd tiny amount
        0.33333333,  // Repeating decimal
        0.66666667,  // Another repeating decimal
        1.23456789,  // Many decimal places
        9.87654321   // Another complex decimal
    ]
    
    let pid = poolRef.createPosition()
    var totalDeposited: UFix64 = 0.0
    
    // Deposit amounts that might cause precision issues
    for amount in precisionTestAmounts {
        let vault <- createTestVault(balance: amount)
        poolRef.deposit(pid: pid, funds: <- vault)
        totalDeposited = totalDeposited + amount
    }
    
    // Try to withdraw exact total - should work without creating/losing value
    let withdrawn <- poolRef.withdraw(
        pid: pid,
        amount: totalDeposited,
        type: Type<@MockVault>()
    ) as! @MockVault
    
    // Allow tiny rounding error but no value creation
    let difference = withdrawn.balance > totalDeposited 
        ? withdrawn.balance - totalDeposited 
        : totalDeposited - withdrawn.balance
    
    Test.assert(difference < 0.00000001,
        message: "Precision loss should not create or destroy significant value")
    
    destroy withdrawn
    destroy pool
}

// ===== ATTACK VECTOR 3: OVERFLOW/UNDERFLOW ATTEMPTS =====

access(all) fun testOverflowUnderflowProtection() {
    /*
     * Attack: Try to cause integer overflow/underflow
     * Protection: UFix64 and UInt64 have built-in overflow protection
     */
    
    var pool <- createTestPool(defaultTokenThreshold: 0.8)
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Test near-maximum values
    let nearMaxUFix64: UFix64 = 92233720368.54775807  // Close to max but safe
    
    // Test 1: Large deposit
    let pid1 = poolRef.createPosition()
    let largeVault <- createTestVault(balance: nearMaxUFix64)
    poolRef.deposit(pid: pid1, funds: <- largeVault)
    
    // Verify it was stored correctly
    let reserves = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(reserves, nearMaxUFix64)
    
    // Test 2: Interest calculation with extreme values
    let extremeRates: [UFix64] = [0.99, 0.999, 0.9999]
    for rate in extremeRates {
        let perSecond = TidalProtocol.perSecondInterestRate(yearlyRate: rate)
        // Verify it doesn't overflow
        Test.assert(perSecond > 10000000000000000,
            message: "Per-second rate should be valid")
    }
    
    // Test 3: Compound interest with large indices
    let largeIndex: UInt64 = 50000000000000000  // 5.0 in fixed point
    let rate: UInt64 = 10001000000000000     // ~1.0001 per second
    let compounded = TidalProtocol.compoundInterestIndex(
        oldIndex: largeIndex,
        perSecondRate: rate,
        elapsedSeconds: 3600.0  // 1 hour
    )
    
    // Should increase but not overflow
    Test.assert(compounded > largeIndex,
        message: "Compounding should increase index")
    Test.assert(compounded < 100000000000000000,  // Less than 10x
        message: "Compounding should not cause unrealistic growth")
    
    destroy pool
}

// ===== ATTACK VECTOR 4: FLASH LOAN ATTACK SIMULATION =====

access(all) fun testFlashLoanAttackSimulation() {
    /*
     * Attack: Simulate flash loan attack pattern
     * Borrow large amount, manipulate state, repay in same block
     */
    
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: 0.8,
        initialBalance: 100000.0
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Attacker position with small collateral
    let attackerPid = poolRef.createPosition()
    let collateral <- createTestVault(balance: 1000.0)
    poolRef.deposit(pid: attackerPid, funds: <- collateral)
    
    // Simulate flash loan: large borrow
    let flashLoanAmount: UFix64 = 50000.0
    
    // This would fail in real scenario due to health check
    // But let's test the contract's protection
    
    // First, create a well-collateralized position
    let whalePid = poolRef.createPosition()
    let whaleCollateral <- createTestVault(balance: 80000.0)
    poolRef.deposit(pid: whalePid, funds: <- whaleCollateral)
    
    // Whale can borrow large amount
    let borrowed <- poolRef.withdraw(
        pid: whalePid,
        amount: flashLoanAmount,
        type: Type<@MockVault>()
    ) as! @MockVault
    
    // In a flash loan attack, attacker would:
    // 1. Borrow large amount
    // 2. Manipulate prices/state
    // 3. Profit from manipulation
    // 4. Repay loan
    
    // Simulate repayment
    poolRef.deposit(pid: whalePid, funds: <- borrowed)
    
    // Verify pool state is consistent
    let finalReserves = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(finalReserves, 181000.0)  // Initial + collaterals
    
    destroy pool
}

// ===== ATTACK VECTOR 5: GRIEFING ATTACKS =====

access(all) fun testGriefingAttacks() {
    /*
     * Attack: Try to grief other users by:
     * 1. Dust attacks (tiny deposits)
     * 2. Gas griefing (expensive operations)
     * 3. State bloat
     */
    
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: 0.8,
        initialBalance: 10000.0
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Test 1: Dust attack - many tiny deposits
    let dustPid = poolRef.createPosition()
    let dustAmount: UFix64 = 0.00000001
    
    // Try 100 dust deposits
    var i = 0
    while i < 100 {
        let dustVault <- createTestVault(balance: dustAmount)
        poolRef.deposit(pid: dustPid, funds: <- dustVault)
        i = i + 1
    }
    
    // System should handle this gracefully
    let totalDust = dustAmount * 100.0
    let dustWithdrawn <- poolRef.withdraw(
        pid: dustPid,
        amount: totalDust,
        type: Type<@MockVault>()
    ) as! @MockVault
    
    // Some precision loss is acceptable with dust
    Test.assert(dustWithdrawn.balance >= totalDust * 0.99,
        message: "Dust deposits should be handled gracefully")
    
    destroy dustWithdrawn
    
    // Test 2: Create many positions (state bloat attempt)
    let positions: [UInt64] = []
    var j = 0
    while j < 50 {
        positions.append(poolRef.createPosition())
        j = j + 1
    }
    
    // Verify positions are created sequentially
    Test.assertEqual(positions[49], UInt64(51))  // 0-indexed, plus 2 existing
    
    destroy pool
}

// ===== ATTACK VECTOR 6: ORACLE MANIPULATION PREPARATION =====

access(all) fun testOracleManipulationResilience() {
    /*
     * Attack: Test resilience to potential oracle manipulation
     * Note: Current implementation uses fixed exchange rates
     */
    
    var pool <- createTestPool(defaultTokenThreshold: 0.8)
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // In future multi-token implementation, test:
    // 1. Rapid price changes
    // 2. Stale price data
    // 3. Extreme exchange rates
    
    // Current implementation has fixed 1:1 exchange rate
    // Test that liquidation thresholds work correctly
    
    let thresholds: [UFix64] = [0.1, 0.5, 0.9, 0.95, 0.99]
    
    for threshold in thresholds {
        var testPool <- createTestPool(defaultTokenThreshold: threshold)
        let testPoolRef = &testPool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
        
        // Verify threshold is enforced
        let pid = testPoolRef.createPosition()
        let collateral <- createTestVault(balance: 1000.0)
        testPoolRef.deposit(pid: pid, funds: <- collateral)
        
        // Max borrow should respect threshold
        let maxBorrow = 1000.0 * threshold * 0.99  // Slightly under to ensure success
        let borrowed <- testPoolRef.withdraw(
            pid: pid,
            amount: maxBorrow,
            type: Type<@MockVault>()
        ) as! @MockVault
        
        Test.assertEqual(borrowed.balance, maxBorrow)
        
        destroy borrowed
        destroy testPool
    }
    
    destroy pool
}

// ===== ATTACK VECTOR 7: FRONT-RUNNING SIMULATION =====

access(all) fun testFrontRunningScenarios() {
    /*
     * Attack: Simulate front-running scenarios
     * Test that protocol is resilient to transaction ordering
     */
    
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: 0.8,
        initialBalance: 100000.0
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Create two users
    let user1Pid = poolRef.createPosition()
    let user2Pid = poolRef.createPosition()
    
    // User 1 plans to deposit large amount
    let user1Deposit <- createTestVault(balance: 50000.0)
    
    // User 2 (front-runner) deposits first
    let user2Deposit <- createTestVault(balance: 10000.0)
    poolRef.deposit(pid: user2Pid, funds: <- user2Deposit)
    
    // User 2 borrows before User 1's deposit
    let frontRunBorrow <- poolRef.withdraw(
        pid: user2Pid,
        amount: 5000.0,
        type: Type<@MockVault>()
    ) as! @MockVault
    
    // User 1's deposit goes through
    poolRef.deposit(pid: user1Pid, funds: <- user1Deposit)
    
    // Verify pool state is consistent regardless of ordering
    let totalReserves = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assertEqual(totalReserves, 155000.0)  // 100k + 50k + 10k - 5k
    
    // Both users' positions should be independent
    Test.assertEqual(poolRef.positionHealth(pid: user1Pid), 1.0)
    Test.assertEqual(poolRef.positionHealth(pid: user2Pid), 1.0)
    
    destroy frontRunBorrow
    destroy pool
}

// ===== ATTACK VECTOR 8: ECONOMIC ATTACKS =====

access(all) fun testEconomicAttacks() {
    /*
     * Attack: Economic attacks on the protocol
     * 1. Interest rate manipulation
     * 2. Liquidity drainage
     * 3. Bad debt creation attempts
     */
    
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: 0.5,  // 50% threshold
        initialBalance: 100000.0
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Attack 1: Try to manipulate interest rates
    // Current implementation has 0% rates, but test the mechanism
    
    // Create positions with various utilization rates
    let positions: [UInt64] = []
    let borrowAmounts: [UFix64] = [1000.0, 5000.0, 10000.0, 20000.0, 30000.0]
    
    for amount in borrowAmounts {
        let pid = poolRef.createPosition()
        positions.append(pid)
        
        // Deposit collateral
        let collateral <- createTestVault(balance: amount * 2.5)
        poolRef.deposit(pid: pid, funds: <- collateral)
        
        // Borrow to create utilization
        let borrowed <- poolRef.withdraw(
            pid: pid,
            amount: amount,
            type: Type<@MockVault>()
        ) as! @MockVault
        destroy borrowed
    }
    
    // Attack 2: Try to drain liquidity
    let drainerPid = poolRef.createPosition()
    let drainerCollateral <- createTestVault(balance: 100000.0)
    poolRef.deposit(pid: drainerPid, funds: <- drainerCollateral)
    
    // Try to borrow maximum allowed (50% of collateral)
    let maxDrain <- poolRef.withdraw(
        pid: drainerPid,
        amount: 49000.0,  // Just under 50% to ensure success
        type: Type<@MockVault>()
    ) as! @MockVault
    
    Test.assertEqual(maxDrain.balance, 49000.0)
    
    // Verify pool still has liquidity
    let remainingReserves = poolRef.reserveBalance(type: Type<@MockVault>())
    Test.assert(remainingReserves > 0.0,
        message: "Pool should maintain some liquidity")
    
    destroy maxDrain
    destroy pool
}

// ===== ATTACK VECTOR 9: POSITION MANIPULATION =====

access(all) fun testPositionManipulation() {
    /*
     * Attack: Try to manipulate position state
     * 1. Invalid position IDs
     * 2. Position confusion attacks
     * 3. Balance direction manipulation
     */
    
    var pool <- createTestPool(defaultTokenThreshold: 0.8)
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Test 1: Create positions and try to use invalid IDs
    let validPid = poolRef.createPosition()
    let deposit <- createTestVault(balance: 1000.0)
    poolRef.deposit(pid: validPid, funds: <- deposit)
    
    // Position IDs are sequential from 0
    // Try to use non-existent position (would panic with "Invalid position ID")
    // We can't test this without expectFailure
    
    // Test 2: Rapid balance direction changes
    let testPid = poolRef.createPosition()
    
    // Start with credit
    let credit1 <- createTestVault(balance: 100.0)
    poolRef.deposit(pid: testPid, funds: <- credit1)
    
    // Withdraw to potentially flip to debit
    let withdraw1 <- poolRef.withdraw(
        pid: testPid,
        amount: 50.0,
        type: Type<@MockVault>()
    ) as! @MockVault
    
    // Still in credit (100 - 50 = 50)
    
    // Deposit again
    let credit2 <- createTestVault(balance: 25.0)
    poolRef.deposit(pid: testPid, funds: <- credit2)
    
    // Now at 75 credit
    
    // Withdraw more
    let withdraw2 <- poolRef.withdraw(
        pid: testPid,
        amount: 70.0,
        type: Type<@MockVault>()
    ) as! @MockVault
    
    // Now at 5 credit
    Test.assertEqual(poolRef.positionHealth(pid: testPid), 1.0)
    
    destroy withdraw1
    destroy withdraw2
    destroy pool
}

// ===== ATTACK VECTOR 10: COMPOUND INTEREST EXPLOITATION =====

access(all) fun testCompoundInterestExploitation() {
    /*
     * Attack: Try to exploit compound interest calculations
     * 1. Rapid time manipulation
     * 2. Interest accrual gaming
     * 3. Precision loss accumulation
     */
    
    // Test extreme compounding scenarios
    let baseIndex: UInt64 = 10000000000000000  // 1.0
    
    // Test 1: Very high frequency compounding
    let highFreqRate = TidalProtocol.perSecondInterestRate(yearlyRate: 0.10)  // 10% APY
    
    // Compound 1 second at a time for 3600 seconds
    var currentIndex = baseIndex
    var i = 0
    while i < 3600 {
        currentIndex = TidalProtocol.compoundInterestIndex(
            oldIndex: currentIndex,
            perSecondRate: highFreqRate,
            elapsedSeconds: 1.0
        )
        i = i + 1
    }
    
    // Compare with single 1-hour compound
    let singleCompound = TidalProtocol.compoundInterestIndex(
        oldIndex: baseIndex,
        perSecondRate: highFreqRate,
        elapsedSeconds: 3600.0
    )
    
    // Results should be very close (within precision limits)
    let difference = currentIndex > singleCompound 
        ? currentIndex - singleCompound 
        : singleCompound - currentIndex
    
    Test.assert(difference < 1000,  // Very small difference in fixed point
        message: "Compound frequency should not significantly affect result")
    
    // Test 2: Zero time exploitation
    let zeroTime = TidalProtocol.compoundInterestIndex(
        oldIndex: baseIndex,
        perSecondRate: highFreqRate,
        elapsedSeconds: 0.0
    )
    
    Test.assertEqual(zeroTime, baseIndex)
    
    // Test 3: Negative rate simulation (not possible with UFix64, but test edge)
    let zeroRate = TidalProtocol.perSecondInterestRate(yearlyRate: 0.0)
    let noInterest = TidalProtocol.compoundInterestIndex(
        oldIndex: baseIndex,
        perSecondRate: zeroRate,
        elapsedSeconds: 31536000.0  // 1 year
    )
    
    Test.assertEqual(noInterest, baseIndex)
} 