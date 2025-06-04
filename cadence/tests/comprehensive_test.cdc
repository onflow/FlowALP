import Test
import "TidalProtocol"

access(all) fun setup() {
    // Deploy DFB first since TidalProtocol imports it
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MOET before TidalProtocol since TidalProtocol imports it
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]  // Initial supply
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

access(all) fun testPoolCreationAndBasicAccess() {
    // Test 1: Create pool with oracle (validates basic access)
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    let pool <- TidalProtocol.createTestPoolWithOracle(defaultToken: Type<String>())
    
    // Test 2: Create position (validates position ID assignment)
    let positionId = pool.createPosition()
    Test.assertEqual(0 as UInt64, positionId)
    
    // Test 3: Check initial health (validates health calculation)
    let health = pool.positionHealth(pid: positionId)
    Test.assertEqual(1.0 as UFix64, health)
    
    // Test 4: Verify supported tokens
    let supportedTokens = pool.getSupportedTokens()
    Test.assert(supportedTokens.length >= 1, message: "Should have at least one supported token")
    
    destroy pool
}

access(all) fun testHealthCalculationSecurity() {
    // Test health calculation functions (validates internal security)
    let healthEmpty = TidalProtocol.healthComputation(effectiveCollateral: 0.0, effectiveDebt: 0.0)
    let healthHealthy = TidalProtocol.healthComputation(effectiveCollateral: 150.0, effectiveDebt: 100.0)
    
    // When both collateral and debt are 0, health should be 0.0 (not UFix64.max)
    Test.assertEqual(0.0 as UFix64, healthEmpty)  // Empty position has 0 health
    Test.assertEqual(1.5 as UFix64, healthHealthy)  // 150/100 = 1.5
}

access(all) fun testAccessControlStructures() {
    // Test Balance Direction enum
    let creditDirection = TidalProtocol.BalanceDirection.Credit
    let debitDirection = TidalProtocol.BalanceDirection.Debit
    Test.assert(creditDirection != debitDirection, message: "Credit and Debit should be different")
    
    // Test PositionBalance structure
    let positionBalance = TidalProtocol.PositionBalance(
        type: Type<String>(),
        direction: TidalProtocol.BalanceDirection.Credit,
        balance: 100.0
    )
    Test.assertEqual(Type<String>(), positionBalance.type)
    Test.assertEqual(100.0 as UFix64, positionBalance.balance)
} 