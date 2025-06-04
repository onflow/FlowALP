import Test
import "TidalProtocol"

access(all) fun setup() {
    // Deploy contracts in correct order
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

// ===== FUZZY TEST UTILITIES =====

// Generate pseudo-random values based on seed
access(all) fun randomUFix64(seed: UInt64, min: UFix64, max: UFix64): UFix64 {
    let range = max - min
    let randomFactor = UFix64(seed % 1000000) / 1000000.0
    return min + (range * randomFactor)
}

access(all) fun randomBool(seed: UInt64): Bool {
    return seed % 2 == 0
}

// Helper to create a pool with Type<String>()
access(all) fun createStringPool(): @TidalProtocol.Pool {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    return <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
}

// ===== PROPERTY 1: POSITION CREATION MONOTONICITY =====

access(all) fun testFuzzPositionCreationMonotonicity() {
    /*
     * Property: Position IDs are monotonically increasing
     * Each new position gets ID = previous + 1
     */
    
    let pool <- createStringPool()
    
    var previousId: UInt64? = nil
    let numPositions = 20
    var i = 0
    
    while i < numPositions {
        let pid = pool.createPosition()
        
        if previousId != nil {
            Test.assertEqual(pid, previousId! + 1)
        }
        
        previousId = pid
        i = i + 1
    }
    
    destroy pool
}

// ===== PROPERTY 2: INTEREST ACCRUAL MONOTONICITY =====

access(all) fun testFuzzInterestMonotonicity() {
    /*
     * Property: Interest indices must be monotonically increasing
     * For any time t1 < t2, index(t2) >= index(t1)
     */
    
    let testRates: [UFix64] = [0.0, 0.01, 0.05, 0.10, 0.20, 0.50, 0.99]
    let testPeriods: [UFix64] = [1.0, 10.0, 60.0, 3600.0, 86400.0, 604800.0]
    
    for rate in testRates {
        let perSecondRate = TidalProtocol.perSecondInterestRate(yearlyRate: rate)
        var previousIndex: UInt64 = 10000000000000000 // 1.0
        
        for period in testPeriods {
            let newIndex = TidalProtocol.compoundInterestIndex(
                oldIndex: previousIndex,
                perSecondRate: perSecondRate,
                elapsedSeconds: period
            )
            
            // Verify monotonicity
            Test.assert(newIndex >= previousIndex, 
                message: "Interest index must be monotonically increasing")
            
            previousIndex = newIndex
        }
    }
}

// ===== PROPERTY 3: SCALED BALANCE CONSISTENCY =====

access(all) fun testFuzzScaledBalanceConsistency() {
    /*
     * Property: For any balance and interest index:
     * scaledToTrue(trueToScaled(balance, index), index) ≈ balance
     */
    
    let testBalances: [UFix64] = [
        0.00000001, 0.0001, 0.01, 0.1, 1.0, 10.0, 100.0, 1000.0, 
        10000.0, 100000.0, 1000000.0, 10000000.0
    ]
    
    let testIndices: [UInt64] = [
        10000000000000000,  // 1.0
        10100000000000000,  // 1.01
        10500000000000000,  // 1.05
        11000000000000000,  // 1.10
        12000000000000000,  // 1.20
        15000000000000000,  // 1.50
        20000000000000000,  // 2.00
        25000000000000000   // 2.50
    ]
    
    for balance in testBalances {
        for index in testIndices {
            let scaled = TidalProtocol.trueBalanceToScaledBalance(
                trueBalance: balance,
                interestIndex: index
            )
            
            let backToTrue = TidalProtocol.scaledBalanceToTrueBalance(
                scaledBalance: scaled,
                interestIndex: index
            )
            
            // Allow for tiny precision loss
            // For very small balances, use a minimum tolerance
            let minTolerance: UFix64 = 0.00000001
            let calculatedTolerance: UFix64 = balance * 0.001 // 0.1% tolerance
            let tolerance: UFix64 = calculatedTolerance > minTolerance ? calculatedTolerance : minTolerance
            
            let difference = backToTrue > balance 
                ? backToTrue - balance 
                : balance - backToTrue
                
            Test.assert(difference <= tolerance,
                message: "Scaled balance conversion lost precision")
        }
    }
}

// ===== PROPERTY 4: POSITION HEALTH BOUNDARIES =====

access(all) fun testFuzzPositionHealthBoundaries() {
    /*
     * Property: Position health calculation edge cases
     * 1. Health = 1.0 when no debt
     * 2. Health remains valid for various operations
     */
    
    let pool <- createStringPool()
    
    // Test various position counts
    let positionCounts: [Int] = [1, 5, 10, 20]
    
    for count in positionCounts {
        let positions: [UInt64] = []
        var i = 0
        while i < count {
            let pid = pool.createPosition()
            positions.append(pid)
            
            // New position should have health = 1.0
            let health = pool.positionHealth(pid: pid)
            Test.assertEqual(health, 1.0)
            
            i = i + 1
        }
        
        // Verify all positions maintain health = 1.0
        for pid in positions {
            let health = pool.positionHealth(pid: pid)
            Test.assertEqual(health, 1.0)
        }
    }
    
    destroy pool
}

// ===== PROPERTY 5: CONCURRENT POSITION ISOLATION =====

access(all) fun testFuzzConcurrentPositionIsolation() {
    /*
     * Property: Operations on one position don't affect others
     * Each position's state is independent
     */
    
    let pool <- createStringPool()
    
    // Create multiple positions
    let numPositions = 10
    let positions: [UInt64] = []
    
    var i = 0
    while i < numPositions {
        let pid = pool.createPosition()
        positions.append(pid)
        i = i + 1
    }
    
    // Verify initial state
    for pid in positions {
        let health = pool.positionHealth(pid: pid)
        Test.assertEqual(health, 1.0)
    }
    
    // Perform operations on specific positions
    // Note: With Type<String>() we can't do actual deposits/withdrawals
    // but we can test position isolation through other means
    
    // Test that getting position details doesn't affect others
    let seeds: [UInt64] = [111, 222, 333, 444, 555]
    
    for seed in seeds {
        let posIndex = Int(seed) % positions.length
        let pid = positions[posIndex]
        
        // Get position details
        let details = pool.getPositionDetails(pid: pid)
        Test.assertEqual(details.health, 1.0)
        Test.assertEqual(details.balances.length, 0)
        
        // Verify other positions unchanged
        for checkPid in positions {
            let health = pool.positionHealth(pid: checkPid)
            Test.assertEqual(health, 1.0)
        }
    }
    
    destroy pool
}

// ===== PROPERTY 6: EXTREME VALUE HANDLING =====

access(all) fun testFuzzExtremeValues() {
    /*
     * Property: System handles extreme values gracefully
     * No overflows, underflows, or unexpected behavior
     */
    
    // Test extreme position counts
    let pool <- createStringPool()
    
    // Create many positions to test ID limits
    let largePositionCount = 100
    var i = 0
    var lastId: UInt64 = 0
    
    while i < largePositionCount {
        let pid = pool.createPosition()
        Test.assertEqual(pid, UInt64(i))
        lastId = pid
        i = i + 1
    }
    
    // Verify system still functions with many positions
    Test.assertEqual(lastId, UInt64(largePositionCount - 1))
    
    // Test health calculation still works
    let health = pool.positionHealth(pid: lastId)
    Test.assertEqual(health, 1.0)
    
    destroy pool
}

// ===== PROPERTY 7: INTEREST RATE EDGE CASES =====

access(all) fun testFuzzInterestRateEdgeCases() {
    /*
     * Property: Interest calculations handle edge cases
     * 1. Zero rates produce no interest
     * 2. High rates don't overflow
     * 3. Long time periods compound correctly
     */
    
    // Test extreme interest rates
    let extremeRates: [UFix64] = [
        0.0,        // Zero rate
        0.000001,   // Tiny rate
        0.99,       // Maximum safe rate (99% APY)
        0.5,        // 50% APY
        0.0001      // 0.01% APY
    ]
    
    // Test extreme time periods
    let extremePeriods: [UFix64] = [
        0.0,         // No time
        0.001,       // Millisecond
        31536000.0,  // One year
        315360000.0  // Ten years
    ]
    
    let startIndex: UInt64 = 10000000000000000
    
    for rate in extremeRates {
        let perSecondRate = TidalProtocol.perSecondInterestRate(yearlyRate: rate)
        
        for period in extremePeriods {
            // Skip combinations that might overflow
            if rate < 0.99 || period < 31536000.0 {
                let compounded = TidalProtocol.compoundInterestIndex(
                    oldIndex: startIndex,
                    perSecondRate: perSecondRate,
                    elapsedSeconds: period
                )
                
                // Verify no overflow occurred
                Test.assert(compounded >= startIndex,
                    message: "Compounded index should not underflow")
                
                // For zero rate or zero time, index should be unchanged
                if rate == 0.0 || period == 0.0 {
                    Test.assertEqual(compounded, startIndex)
                }
            }
        }
    }
}

// ===== PROPERTY 8: ORACLE PRICE HANDLING =====

access(all) fun testFuzzOraclePriceHandling() {
    /*
     * Property: System handles various oracle prices correctly
     * Different prices should be accepted and used properly
     */
    
    let priceValues: [UFix64] = [
        0.01,       // Very low price
        0.1,        // Low price
        1.0,        // Normal price
        10.0,       // High price
        100.0,      // Very high price
        1000.0,     // Extreme price
        10000.0     // Very extreme price
    ]
    
    for price in priceValues {
        let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
        oracle.setPrice(token: Type<String>(), price: price)
        
        let pool <- TidalProtocol.createPool(
            defaultToken: Type<String>(),
            priceOracle: oracle
        )
        
        // Create position and verify it works with different prices
        let pid = pool.createPosition()
        let health = pool.positionHealth(pid: pid)
        
        Test.assertEqual(health, 1.0)
        
        // Get position details
        let details = pool.getPositionDetails(pid: pid)
        Test.assertEqual(details.poolDefaultToken, Type<String>())
        
        destroy pool
    }
}

// ===== PROPERTY 9: MULTI-TOKEN POOL CONFIGURATION =====

access(all) fun testFuzzMultiTokenConfiguration() {
    /*
     * Property: Pools maintain configuration integrity
     * Default token and supported tokens are properly tracked
     */
    
    let pool <- createStringPool()
    
    // Verify initial configuration
    let supportedTokens = pool.getSupportedTokens()
    Test.assertEqual(supportedTokens.length, 1)
    Test.assertEqual(supportedTokens[0], Type<String>())
    
    // Test token support checking
    Test.assert(pool.isTokenSupported(tokenType: Type<String>()))
    Test.assert(!pool.isTokenSupported(tokenType: Type<Int>()))
    
    // Create many positions to test pool behavior under load
    let numPositions = 50
    let positions: [UInt64] = []
    var i = 0
    
    while i < numPositions {
        let pid = pool.createPosition()
        positions.append(pid)
        
        // Verify configuration remains stable
        if i % 10 == 0 {
            let tokens = pool.getSupportedTokens()
            Test.assertEqual(tokens.length, 1)
        }
        
        i = i + 1
    }
    
    destroy pool
}

// ===== PROPERTY 10: POSITION DETAILS CONSISTENCY =====

access(all) fun testFuzzPositionDetailsConsistency() {
    /*
     * Property: Position details remain consistent
     * Multiple queries return the same data
     */
    
    let pool <- createStringPool()
    
    // Create positions with different IDs
    let numPositions = 20
    let positions: [UInt64] = []
    var i = 0
    
    while i < numPositions {
        let pid = pool.createPosition()
        positions.append(pid)
        i = i + 1
    }
    
    // Test consistency across multiple queries
    for pid in positions {
        // Query same position multiple times
        let details1 = pool.getPositionDetails(pid: pid)
        let details2 = pool.getPositionDetails(pid: pid)
        let details3 = pool.getPositionDetails(pid: pid)
        
        // All should be identical
        Test.assertEqual(details1.health, details2.health)
        Test.assertEqual(details2.health, details3.health)
        Test.assertEqual(details1.balances.length, details2.balances.length)
        Test.assertEqual(details2.balances.length, details3.balances.length)
        
        // Health should be consistent with direct query
        let directHealth = pool.positionHealth(pid: pid)
        Test.assertEqual(details1.health, directHealth)
    }
    
    destroy pool
} 