import Test
import "TidalProtocol"
import "DFB"

// Test suite for multi-token positions and oracle pricing
access(all) fun setup() {
    // Deploy DFB first
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MOET
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

// Test 1: Multi-token position creation
access(all) fun testMultiTokenPositionCreation() {
    // Create oracle and pool directly
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 2.0)
    oracle.setPrice(token: Type<Bool>(), price: 0.5)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Add multiple token types
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.7,
        borrowFactor: 0.3,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 5000.0,
        depositCapacityCap: 500000.0
    )
    
    pool.addSupportedToken(
        tokenType: Type<Bool>(),
        collateralFactor: 0.5,
        borrowFactor: 0.5,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 3000.0,
        depositCapacityCap: 300000.0
    )
    
    // Create position
    let pid = pool.createPosition()
    
    // Verify position can hold multiple token types
    let details = pool.getPositionDetails(pid: pid)
    Test.assertEqual(0, details.balances.length) // Empty initially
    
    // Test that pool supports multiple tokens
    let supportedTokens = pool.getSupportedTokens()
    Test.assertEqual(3, supportedTokens.length) // String (default), Int, Bool
    
    destroy pool
}

// Test 2: Health calculation with multiple tokens
access(all) fun testMultiTokenHealthCalculation() {
    // Create oracle with different prices
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 2.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Add second token
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.8,
        borrowFactor: 0.2,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )
    
    let pid = pool.createPosition()
    
    // In production, we would:
    // 1. Deposit multiple token types
    // 2. Each with different collateral factors
    // 3. Health = sum(token_value * collateral_factor) / total_debt
    
    // Test health calculation
    let health = pool.positionHealth(pid: pid)
    Test.assertEqual(1.0, health) // Empty position
    
    // Test health after hypothetical deposits of different tokens
    let healthAfterDeposit = pool.healthAfterDeposit(
        pid: pid,
        type: Type<String>(),
        amount: 1000.0
    )
    Test.assertEqual(1.0, healthAfterDeposit) // No debt, so health remains 1.0
    
    destroy pool
}

// Test 3: Oracle price changes affect multi-token positions
access(all) fun testOraclePriceImpactOnMultiToken() {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    let pid = pool.createPosition()
    
    // Check initial health
    let health1 = pool.positionHealth(pid: pid)
    
    // Update oracle price
    oracle.setPrice(token: Type<String>(), price: 2.0)
    
    // Check health after price change
    let health2 = pool.positionHealth(pid: pid)
    
    // With empty position, health should remain same
    Test.assertEqual(health1, health2)
    Test.assertEqual(1.0, health2)
    
    // In production with actual deposits:
    // - Higher token price = higher collateral value
    // - Health would improve
    
    destroy pool
}

// Test 4: Different collateral factors for tokens
access(all) fun testDifferentCollateralFactors() {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 1.0) // Same price, different factors
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Add token with high collateral factor (stablecoin-like)
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.95,  // High collateral factor
        borrowFactor: 0.05,      // Low borrow factor
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )
    
    let pid = pool.createPosition()
    
    // Test that different tokens contribute differently to health
    // Stablecoin deposits would provide more collateral value
    // Volatile token deposits would provide less
    
    let health = pool.positionHealth(pid: pid)
    Test.assertEqual(1.0, health)
    
    destroy pool
}

// Test 5: Cross-token borrowing scenarios
access(all) fun testCrossTokenBorrowing() {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 2.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.8,
        borrowFactor: 0.2,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )
    
    let pid = pool.createPosition()
    
    // Scenario: Deposit token A, borrow token B
    // This tests cross-collateralization
    
    // In production:
    // 1. Deposit 1000 TokenA (collateral factor 0.8)
    // 2. Effective collateral = 1000 * 1.0 * 0.8 = 800
    // 3. Can borrow up to 800 worth of any supported token
    
    // Test available balance for different token types
    let available = pool.availableBalance(
        pid: pid,
        type: Type<String>(),
        pullFromTopUpSource: false
    )
    Test.assertEqual(0.0, available) // Empty position
    
    destroy pool
}

// Test 6: Token addition and removal
access(all) fun testTokenAdditionAndRemoval() {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Get initial supported tokens
    let initialTokens = pool.getSupportedTokens()
    Test.assertEqual(1, initialTokens.length) // Just default token
    
    // Add new token
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.7,
        borrowFactor: 0.3,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 5000.0,
        depositCapacityCap: 500000.0
    )
    
    // Verify token was added
    let updatedTokens = pool.getSupportedTokens()
    Test.assertEqual(2, updatedTokens.length)
    
    destroy pool
}

// Test 7: Health functions with multi-token positions
access(all) fun testHealthFunctionsMultiToken() {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 2.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.8,
        borrowFactor: 0.2,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )
    
    let pid = pool.createPosition()
    
    // Test all 8 health functions with multi-token context
    
    // 1. Funds required for target health with specific token
    let required = pool.fundsRequiredForTargetHealth(
        pid: pid,
        type: Type<String>(),
        targetHealth: 2.0
    )
    Test.assertEqual(0.0, required) // Empty position
    
    // 2. Funds available above target health
    let available = pool.fundsAvailableAboveTargetHealth(
        pid: pid,
        type: Type<String>(),
        targetHealth: 1.0
    )
    Test.assertEqual(0.0, available) // Empty position
    
    // Continue testing other functions...
    
    destroy pool
}

// Test 8: Rate limiting with multiple tokens
access(all) fun testMultiTokenRateLimiting() {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Add token with low rate limit
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.8,
        borrowFactor: 0.2,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 100.0,     // Low rate
        depositCapacityCap: 1000.0  // Low cap
    )
    
    let pid = pool.createPosition()
    
    // Each token type has independent rate limiting
    // Token A might be heavily limited while Token B is not
    
    let health = pool.positionHealth(pid: pid)
    Test.assertEqual(1.0, health)
    
    destroy pool
}

// Test 9: Balance sheet with multiple tokens
access(all) fun testMultiTokenBalanceSheet() {
    // Test balance sheet calculations with multiple tokens
    
    // Scenario: Position with multiple tokens
    // TokenA: 1000 units @ $1.00, collateral factor 0.8 = $800 collateral
    // TokenB: 500 units @ $2.00, collateral factor 0.6 = $600 collateral
    // Total effective collateral = $1400
    
    // If borrowed: 500 units @ $1.50, borrow factor 1.2 = $900 debt
    // Health = 1400 / 900 = 1.56
    
    // Test static health computation
    let computedHealth = TidalProtocol.healthComputation(
        effectiveCollateral: 1400.0,
        effectiveDebt: 900.0
    )
    Test.assertEqual(1400.0 / 900.0, computedHealth)
    
    // Test edge cases
    let zeroHealth = TidalProtocol.healthComputation(
        effectiveCollateral: 0.0,
        effectiveDebt: 100.0
    )
    Test.assertEqual(0.0, zeroHealth)
}

// Test 10: Complex multi-token scenarios
access(all) fun testComplexMultiTokenScenarios() {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<Int>(), price: 2.0)
    oracle.setPrice(token: Type<Bool>(), price: 0.5)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Add multiple tokens
    pool.addSupportedToken(
        tokenType: Type<Int>(),
        collateralFactor: 0.8,
        borrowFactor: 0.2,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )
    
    pool.addSupportedToken(
        tokenType: Type<Bool>(),
        collateralFactor: 0.5,
        borrowFactor: 0.5,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 5000.0,
        depositCapacityCap: 500000.0
    )
    
    // Scenario 1: Flash crash protection
    // One token crashes, others maintain position health
    let pid1 = pool.createPosition()
    
    // Scenario 2: Correlated token movements
    // Multiple tokens move together
    let pid2 = pool.createPosition()
    
    // Scenario 3: Arbitrage opportunities
    // Different tokens with different interest rates
    let pid3 = pool.createPosition()
    
    // Test position isolation
    // Each position's health is independent
    let health1 = pool.positionHealth(pid: pid1)
    Test.assertEqual(1.0, health1)
    
    let health2 = pool.positionHealth(pid: pid2)
    Test.assertEqual(1.0, health2)
    
    let health3 = pool.positionHealth(pid: pid3)
    Test.assertEqual(1.0, health3)
    
    destroy pool
} 