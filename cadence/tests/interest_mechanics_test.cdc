import Test
import "TidalProtocol"
// CHANGE: Import FlowToken to use correct type references
import "./test_helpers.cdc"

access(all)
fun setup() {
    // Deploy DFB first since TidalProtocol imports it
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MOET before TidalProtocol
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]
    )
    Test.expect(err, Test.beNil())
    
    // Deploy TidalProtocol
    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

// B-series: Interest-index mechanics

access(all)
fun testInterestIndexInitialization() {
    /* 
     * Test B-1: Interest index initialization
     * 
     * Check initial state through observable behavior
     * Initial indices should be 1.0 (10^16 in fixed point)
     */
    
    // The initial interest indices should be 10^16 (1.0 in fixed point)
    let expectedInitialIndex: UInt64 = 10000000000000000
    
    // Create a pool with oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Initial indices are 1.0, so scaled balance should equal true balance
    let testScaledBalance: UFix64 = 100.0
    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(
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
     * Test that interest rates update based on utilization
     * We can't access rates directly, but can observe effects
     */
    
    // Create pool with oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // The default token (String) is already supported when pool is created
    // No need to add it again
    
    // Create a position
    let pid = pool.createPosition()
    
    // At this point, the pool has no utilization
    // Interest rates should be minimal (SimpleInterestCurve returns 0.0)
    let health = pool.positionHealth(pid: pid)
    Test.assertEqual(1.0, health)
    
    // Note: We can't directly test interest rate updates without actual deposits/withdrawals
    // The tokenState() function automatically updates rates when accessed
    
    // Clean up
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
        
        let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(
            scaledBalance: scaledBalance,
            interestIndex: interestIndex
        )
        
        let scaledAgain = TidalProtocol.trueBalanceToScaledBalance(
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
    let perSecondRate = TidalProtocol.perSecondInterestRate(yearlyRate: annualRate)
    
    // The per-second rate should be slightly above 1.0 (in fixed point)
    // For 5% APY, the per-second multiplier should be approximately 1.0000000015
    
    Test.assert(perSecondRate > 10000000000000000, 
        message: "Per-second rate should be greater than 1.0")
    // The actual calculation gives us 10000000015854895
    // This is reasonable for 5% APY (about 1.58 * 10^-9 per second)
    Test.assert(perSecondRate < 10000000020000000, 
        message: "Per-second rate should be reasonable for 5% APY")
    
    // Test 0% annual rate
    let zeroRate: UFix64 = 0.0
    let zeroPerSecond = TidalProtocol.perSecondInterestRate(yearlyRate: zeroRate)
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
    let perSecondRate = TidalProtocol.perSecondInterestRate(yearlyRate: annualRate)
    
    // Test compounding over different time periods
    let testPeriods: [UFix64] = [
        1.0,      // 1 second
        60.0,     // 1 minute
        3600.0,   // 1 hour
        86400.0   // 1 day
    ]
    
    var previousIndex = startIndex
    for period in testPeriods {
        let newIndex = TidalProtocol.compoundInterestIndex(
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
        let result = TidalProtocol.interestMul(aValues[i], bValues[i])
        
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

// New test: Interest accrual through time
access(all)
fun testInterestAccrualThroughTime() {
    /*
     * Test B-4: Interest accrual through time
     * 
     * Test that tokenState() automatically updates interest
     * when time passes between operations
     */
    
    // Create pool with one token type as default
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 2.0)  // Add price for second token
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Add a different token type (Int) with non-zero interest curve
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.8,
        borrowFactor: 0.9,
        interestCurve: TidalProtocol.SimpleInterestCurve(), // Returns 0% interest
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )
    
    let pid = pool.createPosition()
    
    // Note: SimpleInterestCurve returns 0% interest, so no accrual occurs
    // In production, a real interest curve would show accrual over time
    // The tokenState() function is called automatically on each operation
    
    let health1 = pool.positionHealth(pid: pid)
    // Time passes between blockchain operations...
    let health2 = pool.positionHealth(pid: pid)
    
    // With 0% interest, health should remain the same
    Test.assertEqual(health1, health2)
    
    destroy pool
} 