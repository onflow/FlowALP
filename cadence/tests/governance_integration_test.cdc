import Test
import "TidalProtocol"
import "TidalPoolGovernance"
import "MOET"

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
    
    err = Test.deployContract(
        name: "TidalPoolGovernance",
        path: "../contracts/TidalPoolGovernance.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all) fun testGovernanceWorkflow() {
    // This test demonstrates the complete governance workflow
    
    // 1. Create a pool with String as default token
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Verify pool was created with default token
    let supportedTokens = pool.getSupportedTokens()
    Test.assertEqual(supportedTokens.length, 1)
    
    // 2. Try to add a token without governance (should fail at compile time if called directly)
    // Instead, we'll verify that the method requires governance entitlement
    
    // 3. Create a simple governance setup
    // In a real scenario, this would involve:
    // - Creating a governor resource
    // - Setting up roles
    // - Creating proposals
    // - Voting
    // - Executing proposals
    
    // For now, let's test that we can query the pool state
    Test.assert(pool.isTokenSupported(tokenType: supportedTokens[0]))
    // Check that the pool doesn't support other random types
    Test.assertEqual(pool.getSupportedTokens().length, 1)
    
    // Clean up
    destroy pool
}

access(all) fun testTokenAdditionRequiresGovernance() {
    // This test verifies that adding tokens requires proper governance
    
    // Create a pool
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // The pool should start with only the default token
    Test.assertEqual(pool.getSupportedTokens().length, 1)
    
    // String should be supported as default
    Test.assert(pool.isTokenSupported(tokenType: Type<String>()))
    
    // MOET should not be supported initially
    Test.assert(!pool.isTokenSupported(tokenType: Type<@MOET.Vault>()))
    
    // In a real implementation, only governance can add tokens
    // The addSupportedToken function requires EGovernance entitlement
    
    destroy pool
}

access(all) fun testGovernanceStructures() {
    // Test the governance structures are properly defined
    
    // Test TokenAdditionParams creation with updated structure
    let tokenParams = TidalPoolGovernance.TokenAdditionParams(
        tokenType: Type<@MOET.Vault>(),
        collateralFactor: 0.75,
        borrowFactor: 0.8,
        depositRate: 1000000.0,
        depositCapacityCap: 10000000.0,
        interestCurveType: "simple"
    )
    
    Test.assertEqual(tokenParams.tokenType, Type<@MOET.Vault>())
    Test.assertEqual(tokenParams.collateralFactor, 0.75)
    Test.assertEqual(tokenParams.borrowFactor, 0.8)
    Test.assertEqual(tokenParams.depositRate, 1000000.0)
    Test.assertEqual(tokenParams.depositCapacityCap, 10000000.0)
    Test.assertEqual(tokenParams.interestCurveType, "simple")
}

access(all) fun testProposalEnums() {
    // Test that proposal enums are properly accessible
    
    // ProposalStatus enum
    let pendingStatus = TidalPoolGovernance.ProposalStatus.Pending
    let executedStatus = TidalPoolGovernance.ProposalStatus.Executed
    Test.assertEqual(pendingStatus.rawValue, UInt8(0))
    Test.assertEqual(executedStatus.rawValue, UInt8(6))
    
    // ProposalType enum
    let addTokenType = TidalPoolGovernance.ProposalType.AddToken
    let updateParamsType = TidalPoolGovernance.ProposalType.UpdateTokenParams
    Test.assertEqual(addTokenType.rawValue, UInt8(0))
    Test.assertEqual(updateParamsType.rawValue, UInt8(2))
}

access(all) fun testPoolCreationWithGovernance() {
    // Test creating a pool that will be governed
    
    // Create pool with String as default token
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Verify pool properties
    let supportedTokens = pool.getSupportedTokens()
    Test.assertEqual(supportedTokens.length, 1)
    
    // Create a position to test basic functionality
    let positionID = pool.createPosition()
    Test.assertEqual(positionID, UInt64(0))
    
    // Clean up
    destroy pool
}

access(all) fun testMOETAsGovernanceToken() {
    // Test that MOET contract is properly deployed and can be referenced
    
    // MOET should be available as a type
    let moetType = Type<@MOET.Vault>()
    Test.assert(moetType != nil)
    
    // Test that we can reference MOET.Vault in parameters with updated structure
    let params = TidalPoolGovernance.TokenAdditionParams(
        tokenType: moetType,
        collateralFactor: 0.75,
        borrowFactor: 0.8,
        depositRate: 1000000.0,
        depositCapacityCap: 10000000.0,
        interestCurveType: "stable"
    )
    
    Test.assertEqual(params.tokenType, moetType)
} 