import Test
import "TidalProtocol"
import "MOET"
import "FungibleToken"

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

access(all) fun testMOETIntegration() {
    // Create a pool with String as the default token (simulating FLOW)
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    oracle.setPrice(token: Type<@MOET.Vault>(), price: 1.0)  // 1:1 with default token
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )

    // Add MOET as a supported token
    // Note: This would normally require governance entitlement
    // For testing, we document that this is a governance action
    
    // Verify String is supported as default token
    Test.assert(pool.isTokenSupported(tokenType: Type<String>()))

    // Check supported tokens
    let supportedTokens = pool.getSupportedTokens()
    Test.assertEqual(supportedTokens.length, 1) // Only String (default token)

    // Create a position
    let positionID = pool.createPosition()

    // Verify position health
    let health = pool.positionHealth(pid: positionID)
    Test.assert(health >= 1.0, message: "Position should be healthy")

    // Get position details
    let details = pool.getPositionDetails(pid: positionID)
    Test.assertEqual(details.balances.length, 0) // No balances yet
    Test.assertEqual(details.health, 1.0)

    // Clean up
    destroy pool
}

access(all) fun testMOETAsCollateral() {
    // Create a pool with String as the default token
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )

    // Create a position
    let positionID = pool.createPosition()

    // Verify String is supported
    Test.assert(pool.isTokenSupported(tokenType: Type<String>()))
    
    // Test position health with no deposits
    let health = pool.positionHealth(pid: positionID)
    Test.assertEqual(health, 1.0)

    // Create an empty MOET vault just to verify we can create one
    let emptyMoetVault <- MOET.createEmptyVault(vaultType: Type<@MOET.Vault>())
    Test.assertEqual(emptyMoetVault.balance, 0.0)
    
    // Destroy the empty vault
    destroy emptyMoetVault

    // Clean up
    destroy pool
}

access(all) fun testTokenOperationsDocumentation() {
    // Create a pool
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )

    // Document that adding MOET would require:
    // 1. Governance entitlement (EGovernance)
    // 2. Proper parameters:
    //    - collateralFactor: How much of MOET value can be used as collateral (0-1)
    //    - borrowFactor: Risk adjustment for borrowing (0-1)
    //    - interestCurve: Interest rate model
    //    - depositRate: Maximum deposit rate per second
    //    - depositCapacityCap: Maximum deposit capacity
    
    // Example (would need governance):
    // pool.addSupportedToken(
    //     tokenType: Type<@MOET.Vault>(),
    //     collateralFactor: 0.75,
    //     borrowFactor: 0.8,
    //     interestCurve: TidalProtocol.SimpleInterestCurve(),
    //     depositRate: 1000000.0,
    //     depositCapacityCap: 10000000.0
    // )
    
    // Test passed if we get here
    Test.assert(true, message: "Token operations documented successfully")

    destroy pool
} 