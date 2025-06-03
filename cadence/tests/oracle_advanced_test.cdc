import Test
import "TidalProtocol"
import "./test_helpers.cdc"

access(all)
fun setup() {
    // Deploy contracts in the correct order
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

// Test 1: Rapid Price Changes
access(all) fun testRapidPriceChanges() {
    // Create oracle using String type
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    // Create pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Create position
    let pid = pool.createPosition()
    
    // Track health through price changes
    let priceSequence: [UFix64] = [1.0, 0.8, 0.6, 0.4, 0.6, 0.8, 1.0, 1.2, 1.5]
    
    for price in priceSequence {
        oracle.setPrice(token: Type<String>(), price: price)
        let currentHealth = pool.positionHealth(pid: pid)
        
        // With no debt, health should always be 1.0
        Test.assertEqual(currentHealth, 1.0)
    }
    
    destroy pool
}

// Test 2: Price Volatility Impact on Borrowing
access(all) fun testPriceVolatilityBorrowingLimits() {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    // Create pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Create position
    let pid = pool.createPosition()
    
    // Test at different price points
    let testPrices: [UFix64] = [1.0, 2.0, 0.5]
    
    for price in testPrices {
        oracle.setPrice(token: Type<String>(), price: price)
        
        // With empty position, available funds should be 0
        let availableFunds = pool.fundsAvailableAboveTargetHealth(
            pid: pid,
            type: Type<String>(),
            targetHealth: 1.0
        )
        
        Test.assertEqual(availableFunds, 0.0)
    }
    
    destroy pool
}

// Test 3: Multi-Token Oracle Pricing
access(all) fun testMultiTokenOraclePricing() {
    // Create oracle with String default token
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    
    // Set different prices for different token types
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 2.0)    // Different type for testing
    oracle.setPrice(token: Type<Bool>(), price: 0.5)   // Another type
    
    // Create pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Test that prices are correctly set
    let stringPrice = oracle.price(token: Type<String>())
    Test.assertEqual(stringPrice, 1.0)
    
    let intPrice = oracle.price(token: Type<Int>())
    Test.assertEqual(intPrice, 2.0)
    
    let boolPrice = oracle.price(token: Type<Bool>())
    Test.assertEqual(boolPrice, 0.5)
    
    destroy pool
}

// Test 4: Oracle Price Manipulation Resistance
access(all) fun testOracleManipulationResistance() {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    // Create pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Create position
    let pid = pool.createPosition()
    
    // Attempt 1: Flash crash price
    oracle.setPrice(token: Type<String>(), price: 0.1)
    let crashHealth = pool.positionHealth(pid: pid)
    
    // Immediately restore price
    oracle.setPrice(token: Type<String>(), price: 1.0)
    let restoredHealth = pool.positionHealth(pid: pid)
    
    // With no debt, health should remain 1.0 regardless
    Test.assertEqual(crashHealth, 1.0)
    Test.assertEqual(restoredHealth, 1.0)
    
    // Attempt 2: Pump price
    oracle.setPrice(token: Type<String>(), price: 10.0)
    
    let availableAfterPump = pool.fundsAvailableAboveTargetHealth(
        pid: pid,
        type: Type<String>(),
        targetHealth: 1.0
    )
    
    // With no collateral, available should still be 0
    Test.assertEqual(availableAfterPump, 0.0)
    
    destroy pool
}

// Test 5: Extreme Price Scenarios
access(all) fun testExtremePriceScenarios() {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    // Create pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Create position
    let pid = pool.createPosition()
    
    // Test extreme prices
    let extremePrices: [UFix64] = [
        0.00000001,  // Near zero
        0.001,       // Very low
        1000.0,      // Very high
        100000.0     // Extremely high
    ]
    
    for price in extremePrices {
        oracle.setPrice(token: Type<String>(), price: price)
        
        // System should not panic
        let health = pool.positionHealth(pid: pid)
        Test.assertEqual(health, 1.0)
        
        // Try to calculate other functions
        let available = pool.fundsAvailableAboveTargetHealth(
            pid: pid,
            type: Type<String>(),
            targetHealth: 1.0
        )
        Test.assertEqual(available, 0.0)
    }
    
    destroy pool
}

// Test 6: Oracle Fallback Behavior
access(all) fun testOracleFallbackBehavior() {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    
    // Test with zero price
    oracle.setPrice(token: Type<String>(), price: 0.0)
    
    // Create pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Create position
    let pid = pool.createPosition()
    
    // Health calculation with zero price should handle gracefully
    let zeroHealth = pool.positionHealth(pid: pid)
    Test.assertEqual(zeroHealth, 1.0)
    
    // Set valid price and verify
    oracle.setPrice(token: Type<String>(), price: 1.0)
    let normalHealth = pool.positionHealth(pid: pid)
    Test.assertEqual(normalHealth, 1.0)
    
    destroy pool
}

// Test 7: Cross-Token Price Correlation
access(all) fun testCrossTokenPriceCorrelation() {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@MockVault>())
    
    // Set initial prices
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 5.0)
    
    // Create pool
    var pool <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        priceOracle: oracle
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Add both tokens
    pool.addSupportedToken(
        tokenType: Type<@MockVault>(),
        collateralFactor: 1.0,
        borrowFactor: 0.9,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000000.0,
        depositCapacityCap: 1000000.0
    )
    
    pool.addSupportedToken(
        tokenType: Type<@FlowToken.Vault>(),
        collateralFactor: 0.8,
        borrowFactor: 0.8,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000000.0,
        depositCapacityCap: 1000000.0
    )
    
    // Create position with both tokens
    let pid = poolRef.createPosition()
    
    // Deposit stablecoin
    let stableCollateral <- createTestVault(balance: 500.0)
    poolRef.deposit(pid: pid, funds: <-stableCollateral)
    
    // Note: In real implementation would deposit FLOW tokens too
    // For test purposes, we'll work with single token type
    
    // Simulate market crash - all prices drop
    oracle.setPrice(token: Type<@MockVault>(), price: 0.9)    // -10%
    oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 2.5)  // -50%
    
    let crashHealth = poolRef.positionHealth(pid: pid)
    
    // Simulate recovery
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 5.0)
    
    let recoveryHealth = poolRef.positionHealth(pid: pid)
    
    Test.assert(recoveryHealth > crashHealth,
        message: "Health should recover with price recovery")
    
    destroy pool
}

// Test 8: Oracle Update Frequency Impact
access(all) fun testOracleUpdateFrequency() {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@MockVault>())
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    
    // Create pool
    var pool <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        priceOracle: oracle
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Add token
    pool.addSupportedToken(
        tokenType: Type<@MockVault>(),
        collateralFactor: 0.8,
        borrowFactor: 0.8,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000000.0,
        depositCapacityCap: 1000000.0
    )
    
    // Create position
    let pid = poolRef.createPosition()
    let collateral <- createTestVault(balance: 1000.0)
    poolRef.deposit(pid: pid, funds: <-collateral)
    
    // Simulate high-frequency updates
    var i = 0
    while i < 10 {
        let price = 1.0 + (UFix64(i) * 0.01)  // Small increments
        oracle.setPrice(token: Type<@MockVault>(), price: price)
        
        // Each update should be reflected immediately
        let health = poolRef.positionHealth(pid: pid)
        Test.assert(health > 0.0, message: "Health should be calculable at any time")
        
        i = i + 1
    }
    
    // Simulate low-frequency update (big jump)
    oracle.setPrice(token: Type<@MockVault>(), price: 2.0)
    let jumpHealth = poolRef.positionHealth(pid: pid)
    
    Test.assert(jumpHealth > 1.0,
        message: "Large price jump should significantly improve health")
    
    destroy pool
}

// Test 9: Price Impact on Liquidations
access(all) fun testPriceImpactOnLiquidations() {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@MockVault>())
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    
    // Create pool
    var pool <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        priceOracle: oracle
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Add token with specific factors
    pool.addSupportedToken(
        tokenType: Type<@MockVault>(),
        collateralFactor: 0.75,  // 75% collateral value
        borrowFactor: 0.75,      // 75% borrow efficiency
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000000.0,
        depositCapacityCap: 1000000.0
    )
    
    // Create position near liquidation
    let pid = poolRef.createPosition()
    let collateral <- createTestVault(balance: 1000.0)
    poolRef.deposit(pid: pid, funds: <-collateral)
    
    // Borrow close to limit
    let borrowed <- poolRef.withdraw(
        pid: pid,
        amount: 700.0,  // Close to 75% limit
        type: Type<@MockVault>()
    ) as! @MockVault
    
    let initialHealth = poolRef.positionHealth(pid: pid)
    
    // Drop price to trigger liquidation territory
    oracle.setPrice(token: Type<@MockVault>(), price: 0.9)
    let lowHealth = poolRef.positionHealth(pid: pid)
    
    Test.assert(lowHealth < initialHealth,
        message: "Health should decrease with collateral price drop")
    
    // Further price drop
    oracle.setPrice(token: Type<@MockVault>(), price: 0.8)
    let criticalHealth = poolRef.positionHealth(pid: pid)
    
    Test.assert(criticalHealth < lowHealth,
        message: "Health should continue decreasing with price")
    
    // Check if position would be liquidatable
    // (Actual liquidation logic would be in separate contract)
    Test.assert(criticalHealth < 1.1,
        message: "Position should be near or below liquidation threshold")
    
    destroy borrowed
    destroy pool
}

// Test 10: Oracle Integration Stress Test
access(all) fun testOracleIntegrationStress() {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@MockVault>())
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    
    // Create pool
    var pool <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        priceOracle: oracle
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    // Add token
    pool.addSupportedToken(
        tokenType: Type<@MockVault>(),
        collateralFactor: 0.8,
        borrowFactor: 0.8,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000000.0,
        depositCapacityCap: 1000000.0
    )
    
    // Create multiple positions
    let positions: [UInt64] = []
    var i = 0
    while i < 10 {
        let pid = poolRef.createPosition()
        positions.append(pid)
        
        let collateral <- createTestVault(balance: 100.0 * UFix64(i + 1))
        poolRef.deposit(pid: pid, funds: <-collateral)
        
        i = i + 1
    }
    
    // Rapid price changes while positions active
    let stressPrices: [UFix64] = [1.0, 0.5, 2.0, 0.3, 3.0, 0.7, 1.5, 0.9, 1.1, 1.0]
    
    for price in stressPrices {
        oracle.setPrice(token: Type<@MockVault>(), price: price)
        
        // Check all positions remain calculable
        for pid in positions {
            let health = poolRef.positionHealth(pid: pid)
            Test.assert(health >= 0.0, message: "All positions should remain calculable")
        }
    }
    
    destroy pool
} 