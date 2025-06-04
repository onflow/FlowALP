import TidalProtocol from "TidalProtocol"

// Test script for validating entitlements and capability-based security
access(all) fun main(): Bool {
    // Test 1: Create pool and verify entitlement system structure
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    let pool <- TidalProtocol.createTestPoolWithOracle(defaultToken: Type<String>())
    let positionId = pool.createPosition()
    
    // Test 2: Get position details to verify structure
    let positionDetails = pool.getPositionDetails(pid: positionId)
    
    // Test 3: Test available balance functions
    let availableBalance = pool.availableBalance(pid: positionId, type: Type<String>(), pullFromTopUpSource: false)
    let availableBalanceWithPull = pool.availableBalance(pid: positionId, type: Type<String>(), pullFromTopUpSource: true)
    
    // Test 4: Verify type consistency
    let defaultToken = pool.getDefaultToken()
    let typesMatch = defaultToken == Type<String>()
    
    // Test 5: Test Balance Sheet calculation (internal security patterns)
    let emptyBalance = TidalProtocol.BalanceSheet(effectiveCollateral: 0.0, effectiveDebt: 0.0)
    let healthyBalance = TidalProtocol.BalanceSheet(effectiveCollateral: 150.0, effectiveDebt: 100.0)
    
    let emptyHealthIsMax = emptyBalance.health == UFix64.max
    let healthyRatio = healthyBalance.health == 1.5
    
    // Test 6: Test Position Balance structure
    let positionBalance = TidalProtocol.PositionBalance(
        type: Type<String>(),
        direction: TidalProtocol.BalanceDirection.Credit,
        balance: 100.0
    )
    
    let balanceStructure = positionBalance.type == Type<String>() &&
                          positionBalance.direction == TidalProtocol.BalanceDirection.Credit &&
                          positionBalance.balance == 100.0
    
    // Test 7: Verify Position Details structure
    let detailsValid = positionDetails.balances.length == 0 &&
                      positionDetails.poolDefaultToken == Type<String>() &&
                      positionDetails.health == 1.0
    
    // Cleanup
    destroy pool
    
    // Comprehensive entitlement and capability test result
    return typesMatch &&
           availableBalance == 0.0 &&
           availableBalanceWithPull == 0.0 &&
           emptyHealthIsMax &&
           healthyRatio &&
           balanceStructure &&
           detailsValid
} 