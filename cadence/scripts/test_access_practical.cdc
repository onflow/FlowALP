import TidalProtocol from "TidalProtocol"

// Test practical access control scenarios
access(all) fun main(): Bool {
    // Test 1: Create pool and verify public access
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    let pool <- TidalProtocol.createTestPoolWithOracle(defaultToken: Type<String>())
    
    // Test 2: Public functions should work
    let positionId = pool.createPosition()
    let health = pool.positionHealth(pid: positionId)
    let supportedTokens = pool.getSupportedTokens()
    
    // Test 3: Verify position details access
    let details = pool.getPositionDetails(pid: positionId)
    
    // Test 4: Check all public getters work
    let isSupported = pool.isTokenSupported(tokenType: Type<String>())
    let reserveBalance = pool.reserveBalance(type: Type<String>())
    
    // Get default token from position details
    let defaultToken = details.poolDefaultToken
    
    // Cleanup
    destroy pool
    
    // All tests passed if we got here
    return health == 1.0 && 
           details.health == 1.0 && 
           supportedTokens.length >= 1 &&
           defaultToken == Type<String>() &&
           isSupported &&
           reserveBalance == 0.0
} 