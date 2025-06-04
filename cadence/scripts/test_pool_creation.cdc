import TidalProtocol from "TidalProtocol"

// Test script for validating pool creation with proper access control
access(all) fun main(): Bool {
    // Test 1: Create a pool with String as default token (simulating FlowToken)
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    let pool <- TidalProtocol.createTestPoolWithOracle(defaultToken: Type<String>())
    
    // Test 2: Verify pool supports the default token
    let supportedTokens = pool.getSupportedTokens()
    let hasDefaultToken = supportedTokens.contains(Type<String>())
    
    // Test 3: Create a position and verify ID assignment
    let positionId = pool.createPosition()
    let expectedFirstId: UInt64 = 0
    
    // Test 4: Check position health (should be 1.0 for empty position)
    let initialHealth = pool.positionHealth(pid: positionId)
    let healthIsCorrect = initialHealth == 1.0
    
    // Test 5: Verify position details structure
    let positionDetails = pool.getPositionDetails(pid: positionId)
    let hasCorrectDefaultToken = positionDetails.poolDefaultToken == Type<String>()
    let hasCorrectHealth = positionDetails.health == 1.0
    let hasEmptyBalances = positionDetails.balances.length == 0
    
    // Cleanup
    destroy pool
    
    // Return comprehensive test result
    return hasDefaultToken && 
           positionId == expectedFirstId && 
           healthIsCorrect && 
           hasCorrectDefaultToken && 
           hasCorrectHealth && 
           hasEmptyBalances
} 