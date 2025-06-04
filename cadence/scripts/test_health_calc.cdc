import TidalProtocol from "TidalProtocol"

// Test health calculation functions
access(all) fun main(): Bool {
    // Test 1: Empty position (no debt)
    let healthEmpty = TidalProtocol.healthComputation(effectiveCollateral: 0.0, effectiveDebt: 0.0)
    let emptyCorrect = healthEmpty == 0.0
    
    // Test 2: Healthy position
    let healthHealthy = TidalProtocol.healthComputation(effectiveCollateral: 150.0, effectiveDebt: 100.0)
    let healthyCorrect = healthHealthy == 1.5
    
    // Test 3: Overcollateralized position
    let healthOver = TidalProtocol.healthComputation(effectiveCollateral: 200.0, effectiveDebt: 50.0)
    let overCorrect = healthOver == 4.0
    
    // Test 4: Undercollateralized position
    let healthUnder = TidalProtocol.healthComputation(effectiveCollateral: 80.0, effectiveDebt: 100.0)
    let underCorrect = healthUnder == 0.8
    
    // Test 5: DummyPriceOracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    let defaultPrice = oracle.price(token: Type<String>())
    let priceCorrect = defaultPrice == 1.0
    
    // Return comprehensive result
    return emptyCorrect && healthyCorrect && overCorrect && underCorrect && priceCorrect
} 