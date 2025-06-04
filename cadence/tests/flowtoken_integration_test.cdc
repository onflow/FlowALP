import Test
import "TidalProtocol"
import "FlowToken"
import "FungibleToken"
import "MOET"

access(all) fun setup() {
    // Deploy all contracts in the correct order
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

// Helper function to create a pool with FlowToken as default token
access(all) fun createFlowTokenPool(): @TidalProtocol.Pool {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@FlowToken.Vault>())
    oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 1.0)
    oracle.setPrice(token: Type<@MOET.Vault>(), price: 0.5)  // 1 MOET = 0.5 FLOW
    
    return <- TidalProtocol.createPool(
        defaultToken: Type<@FlowToken.Vault>(),
        priceOracle: oracle
    )
}

access(all) fun testFlowTokenIntegration() {
    // Create a pool with FlowToken as the default token
    let pool <- createFlowTokenPool()
    let poolRef = &pool as auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool

    // Add MOET as a supported token
    poolRef.addSupportedToken(
        tokenType: Type<@MOET.Vault>(),
        collateralFactor: 0.75,
        borrowFactor: 0.9,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )

    // Verify both tokens are supported
    Test.assert(poolRef.isTokenSupported(tokenType: Type<@FlowToken.Vault>()))
    Test.assert(poolRef.isTokenSupported(tokenType: Type<@MOET.Vault>()))

    // Get supported tokens list
    let supportedTokens = poolRef.getSupportedTokens()
    Test.assertEqual(supportedTokens.length, 2)
    
    // Check that both token types are in the array (order doesn't matter)
    let hasFlowToken = supportedTokens.contains(Type<@FlowToken.Vault>())
    let hasMOET = supportedTokens.contains(Type<@MOET.Vault>())
    Test.assert(hasFlowToken)
    Test.assert(hasMOET)

    // Clean up
    destroy pool
}

access(all) fun testFlowTokenType() {
    // Simple test to verify FlowToken type can be referenced
    // This avoids inline code while still testing FlowToken availability
    
    let flowTokenType = Type<@FlowToken.Vault>()
    let moetType = Type<@MOET.Vault>()
    
    // Verify types are different
    Test.assert(flowTokenType != moetType)
    
    // Create a pool with FlowToken and oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: flowTokenType)
    oracle.setPrice(token: flowTokenType, price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: flowTokenType,
        priceOracle: oracle
    )
    
    // Verify the pool was created with FlowToken
    let supportedTokens = pool.getSupportedTokens()
    Test.assertEqual(supportedTokens.length, 1)
    Test.assertEqual(supportedTokens[0], flowTokenType)
    
    destroy pool
}

access(all) fun testPoolWithFlowTokenAndMOET() {
    // Create a pool that uses FlowToken as base and can accept MOET
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@FlowToken.Vault>())
    oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 1.0)
    oracle.setPrice(token: Type<@MOET.Vault>(), price: 0.5)  // 1 MOET = 0.5 FLOW
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<@FlowToken.Vault>(),
        priceOracle: oracle
    )
    let poolRef = &pool as auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool

    // Add MOET with specific parameters
    poolRef.addSupportedToken(
        tokenType: Type<@MOET.Vault>(),
        collateralFactor: 0.7,
        borrowFactor: 0.8,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )

    // Create a position
    let positionID = poolRef.createPosition()
    Test.assertEqual(positionID, UInt64(0))
    
    // Check that we can query the pool's state
    Test.assertEqual(poolRef.reserveBalance(type: Type<@FlowToken.Vault>()), 0.0)
    Test.assertEqual(poolRef.reserveBalance(type: Type<@MOET.Vault>()), 0.0)
    
    // Verify position details
    let positionDetails = poolRef.getPositionDetails(pid: positionID)
    Test.assertEqual(positionDetails.balances.length, 0)
    Test.assertEqual(positionDetails.health, 1.0)
    Test.assertEqual(positionDetails.poolDefaultToken, Type<@FlowToken.Vault>())
    
    destroy pool
} 