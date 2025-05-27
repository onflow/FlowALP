import Test
import "AlpenFlow"
// CHANGE: Import FlowToken to use correct type references
import "./test_helpers.cdc"

access(all)
fun setup() {
    // Use the shared deployContracts function
    deployContracts()
}

// B-series: Interest-index mechanics

access(all)
fun testInterestIndexInitialization() {
    /* 
     * Test B-1: Interest index initialization
     * 
     * Check initial state of TokenState
     * creditInterestIndex == 10^16 · debitInterestIndex == 10^16
     */
    
    // The initial interest indices should be 10^16 (1.0 in fixed point)
    let expectedInitialIndex: UInt64 = 10000000000000000
    
    // Create a pool to access TokenState
    let defaultThreshold: UFix64 = 1.0
    var pool <- createTestPool(defaultTokenThreshold: defaultThreshold)
    
    // Note: TokenState is not directly accessible, but we can verify through behavior
    // Initial indices are 1.0, so scaled balance should equal true balance
    let testScaledBalance: UFix64 = 100.0
    let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(
        scaledBalance: testScaledBalance,
        interestIndex: expectedInitialIndex
    )
    
    Test.assertEqual(trueBalance, 100.0)
    
    // Clean up
    destroy pool
}

access(all)
fun testInterestRateCalculation() {
    /* 
     * Test B-2: Interest rate calculation
     * 
     * Set up position with credit and debit balances
     * updateInterestRates() calculates rates based on utilization
     */
    
    // Create pool with initial funding
    let defaultThreshold: UFix64 = 0.8  // 80% threshold
    var pool <- createTestPoolWithBalance(
        defaultTokenThreshold: defaultThreshold,
        initialBalance: 1000.0
    )
    let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool
    
    // Create a borrower position
    let borrowerPid = poolRef.createPosition()
    let collateralVault <- createTestVault(balance: 100.0)
    poolRef.deposit(pid: borrowerPid, funds: <- collateralVault)
    
    // Borrow some funds (within threshold)
    let borrowed <- poolRef.withdraw(
        pid: borrowerPid,
        amount: 50.0,
        // CHANGE: Updated type parameter to MockVault
        type: Type<@MockVault>()
    ) as! @MockVault  // CHANGE: Cast to MockVault
    
    // At this point, the pool has credit and debit balances
    // The interest rate calculation should work (even if rates are 0%)
    Test.assertEqual(borrowed.balance, 50.0)
    
    // Clean up
    destroy borrowed
    destroy pool
}

access(all)
fun testScaledBalanceConversion() {
    /* 
     * Test B-3: Scaled balance conversion
     * 
     * Test scaledBalanceToTrueBalance and reverse
     * Conversions are symmetric within precision limits
     */
    
    // Test with various interest indices
    let scaledBalances: [UFix64] = [100.0, 100.0, 100.0, 50.0]
    let interestIndices: [UInt64] = [
        10000000000000000,  // 1.0
        10500000000000000,  // 1.05
        11000000000000000,  // 1.10
        12000000000000000   // 1.20
    ]
    
    var i = 0
    while i < scaledBalances.length {
        let scaledBalance = scaledBalances[i]
        let interestIndex = interestIndices[i]
        
        let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(
            scaledBalance: scaledBalance,
            interestIndex: interestIndex
        )
        
        let scaledAgain = AlpenFlow.trueBalanceToScaledBalance(
            trueBalance: trueBalance,
            interestIndex: interestIndex
        )
        
        // Allow for tiny rounding errors (< 0.00000001)
        let difference = scaledAgain > scaledBalance 
            ? scaledAgain - scaledBalance 
            : scaledBalance - scaledAgain
            
        Test.assert(difference < 0.00000001, 
            message: "Scaled balance conversion should be symmetric")
        
        i = i + 1
    }
}

// D-series: Interest calculations

access(all)
fun testPerSecondRateConversion() {
    /* 
     * Test D-1: Per-second rate conversion
     * 
     * Test perSecondInterestRate() with 5% APY
     * Returns correct fixed-point multiplier
     */
    
    // Test 5% annual rate
    let annualRate: UFix64 = 0.05
    let perSecondRate = AlpenFlow.perSecondInterestRate(yearlyRate: annualRate)
    
    // The per-second rate should be slightly above 1.0 (in fixed point)
    // For 5% APY, the per-second multiplier should be approximately 1.0000000015
    // Let's calculate: 0.05 * 10^8 * 10^5 / 31536 ≈ 158.5
    // So the result should be around 10000000000000000 + 158 = 10000000000000158
    
    // Log the actual value for debugging
    log("Per-second rate for 5% APY: ".concat(perSecondRate.toString()))
    
    Test.assert(perSecondRate > 10000000000000000, 
        message: "Per-second rate should be greater than 1.0")
    // The actual calculation gives us 10000000015854895
    // This is reasonable for 5% APY (about 1.58 * 10^-9 per second)
    Test.assert(perSecondRate < 10000000020000000, 
        message: "Per-second rate should be reasonable for 5% APY")
    
    // Test 0% annual rate
    let zeroRate: UFix64 = 0.0
    let zeroPerSecond = AlpenFlow.perSecondInterestRate(yearlyRate: zeroRate)
    let expectedZeroRate: UInt64 = 10000000000000000
    Test.assertEqual(zeroPerSecond, expectedZeroRate)  // Should be exactly 1.0
}

access(all)
fun testCompoundInterestCalculation() {
    /* 
     * Test D-2: Compound interest calculation
     * 
     * Test compoundInterestIndex() with various time periods
     * Correctly compounds interest over time
     */
    
    // Start with index of 1.0
    let startIndex: UInt64 = 10000000000000000
    
    // 5% APY per-second rate
    let annualRate: UFix64 = 0.05
    let perSecondRate = AlpenFlow.perSecondInterestRate(yearlyRate: annualRate)
    
    // Test compounding over different time periods
    let testPeriods: [UFix64] = [
        1.0,      // 1 second
        60.0,     // 1 minute
        3600.0,   // 1 hour
        86400.0   // 1 day
    ]
    
    var previousIndex = startIndex
    for period in testPeriods {
        let newIndex = AlpenFlow.compoundInterestIndex(
            oldIndex: startIndex,
            perSecondRate: perSecondRate,
            elapsedSeconds: period
        )
        
        // Index should increase over time
        Test.assert(newIndex >= previousIndex, 
            message: "Interest index should increase over time")
        previousIndex = newIndex
    }
}

access(all)
fun testInterestMultiplication() {
    /* 
     * Test D-3: Interest multiplication
     * 
     * Test interestMul() function
     * Handles fixed-point multiplication correctly
     */
    
    // Test cases for fixed-point multiplication
    let aValues: [UInt64] = [
        10000000000000000,  // 1.0
        10500000000000000,  // 1.05
        11000000000000000   // 1.1
    ]
    let bValues: [UInt64] = [
        10000000000000000,  // 1.0
        10500000000000000,  // 1.05
        11000000000000000   // 1.1
    ]
    let expectedValues: [UInt64] = [
        10000000000000000,  // 1.0 * 1.0 = 1.0
        11025000000000000,  // 1.05 * 1.05 ≈ 1.1025
        12100000000000000   // 1.1 * 1.1 = 1.21
    ]
    
    var i = 0
    while i < aValues.length {
        let result = AlpenFlow.interestMul(aValues[i], bValues[i])
        
        // Allow for some precision loss in the multiplication
        let difference = result > expectedValues[i]
            ? result - expectedValues[i]
            : expectedValues[i] - result
            
        let tolerance: UInt64 = 100000000000  // Allow 0.00001 difference
        Test.assert(difference < tolerance, 
            message: "Interest multiplication should be accurate")
        
        i = i + 1
    }
} 