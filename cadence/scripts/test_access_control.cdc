import TidalProtocol from "TidalProtocol"

// Test script for validating access control and entitlements
access(all) fun main(): Bool {
    // Test 1: Create pool and position (tests public access)
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    let pool <- TidalProtocol.createTestPoolWithOracle(defaultToken: Type<String>())
    let positionId = pool.createPosition()
    
    // Test 2: Verify public functions work without special entitlements
    let health = pool.positionHealth(pid: positionId)
    let supportedTokens = pool.getSupportedTokens()
    let tokenSupported = pool.isTokenSupported(tokenType: Type<String>())
    let reserveBalance = pool.reserveBalance(type: Type<String>())
    
    // Test 3: Get position details instead of creating Position struct
    let positionDetails = pool.getPositionDetails(pid: positionId)
    let positionHealth = positionDetails.health
    let positionBalances = positionDetails.balances
    let availableBalance = positionDetails.defaultTokenAvailableBalance
    
    // Test 4: Test that health functions return expected values for empty position
    let healthIsOne = health == 1.0 && positionHealth == 1.0
    let balancesEmpty = positionBalances.length == 0
    let reserveIsZero = reserveBalance == 0.0
    let availableIsZero = availableBalance == 0.0
    
    // Test 5: Verify DummyPriceOracle works correctly
    let oracleUnitOfAccount = oracle.unitOfAccount()
    let defaultTokenPrice = oracle.price(token: Type<String>())
    let priceIsOne = defaultTokenPrice == 1.0
    let correctUnitOfAccount = oracleUnitOfAccount == Type<String>()
    
    // Test 6: Verify helper functions work
    let healthCalc = TidalProtocol.healthComputation(effectiveCollateral: 100.0, effectiveDebt: 50.0)
    let healthIs2 = healthCalc == 2.0
    
    // Test 7: Verify Balance Direction enum
    let creditDirection = TidalProtocol.BalanceDirection.Credit
    let debitDirection = TidalProtocol.BalanceDirection.Debit
    let directionsWork = creditDirection != debitDirection
    
    // Cleanup
    destroy pool
    
    // Comprehensive result
    return healthIsOne && 
           balancesEmpty && 
           reserveIsZero && 
           availableIsZero && 
           priceIsOne && 
           correctUnitOfAccount && 
           healthIs2 && 
           directionsWork && 
           tokenSupported && 
           supportedTokens.length >= 1
} 