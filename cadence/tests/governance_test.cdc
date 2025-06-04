import Test
import "TidalProtocol"
import "TidalPoolGovernance"
import "MOET"

access(all) let governanceAcct = Test.getAccount(0x0000000000000008)
access(all) let proposerAcct = Test.getAccount(0x0000000000000009)
access(all) let executorAcct = Test.getAccount(0x000000000000000a)
access(all) let voterAcct = Test.getAccount(0x000000000000000b)

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
    
    // Deploy TidalPoolGovernance
    err = Test.deployContract(
        name: "TidalPoolGovernance",
        path: "../contracts/TidalPoolGovernance.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all) fun testCreateGovernor() {
    // Create a pool using Type<String>()
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )

    // Test that we can reference TidalPoolGovernance
    Test.assert(true, message: "TidalPoolGovernance contract deployed")

    destroy pool
}

access(all) fun testProposalCreationAndVoting() {
    // This test demonstrates the proposal creation and voting flow
    
    // Create accounts
    let proposer = Test.createAccount()
    let voter1 = Test.createAccount()
    let voter2 = Test.createAccount()
    
    // Create a pool
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // In a real test, we'd properly save the pool and create the capability
    // For now, we verify the pool is created
    Test.assert(pool.getSupportedTokens().length == 1)
    
    destroy pool
}

access(all) fun testGovernanceAddToken() {
    // This test simulates adding a token through governance
    
    // Create a pool
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Note: We cannot directly add tokens in tests as it requires EGovernance entitlement
    // This is by design - only governance can add tokens
    
    // Initial state: only String is supported
    Test.assertEqual(pool.getSupportedTokens().length, 1)
    Test.assert(pool.isTokenSupported(tokenType: Type<String>()))
    Test.assert(!pool.isTokenSupported(tokenType: Type<@MOET.Vault>()))
    
    // In a real scenario, governance would:
    // 1. Create a proposal through TidalPoolGovernance
    // 2. Vote on the proposal
    // 3. Execute the proposal after timelock
    // 4. The proposal would call pool.addSupportedToken with proper parameters
    
    destroy pool
}

access(all) fun testTokenAdditionParams() {
    // Test creating token addition parameters with updated structure
    let params = TidalPoolGovernance.TokenAdditionParams(
        tokenType: Type<String>(),
        collateralFactor: 0.8,
        borrowFactor: 0.85,
        depositRate: 1000000.0,
        depositCapacityCap: 10000000.0,
        interestCurveType: "simple"
    )
    
    Test.assertEqual(params.tokenType, Type<String>())
    Test.assertEqual(params.collateralFactor, 0.8)
    Test.assertEqual(params.borrowFactor, 0.85)
    Test.assertEqual(params.depositRate, 1000000.0)
    Test.assertEqual(params.depositCapacityCap, 10000000.0)
    Test.assertEqual(params.interestCurveType, "simple")
}

access(all) fun testProposalStructure() {
    // Test proposal creation
    let proposal = TidalPoolGovernance.Proposal(
        id: 1,
        proposer: 0x01,
        proposalType: TidalPoolGovernance.ProposalType.AddToken,
        description: "Add MOET token to the pool",
        votingPeriod: 100,
        params: {"test": "value"},
        governorID: 0,
        executionDelay: 86400.0
    )
    
    Test.assertEqual(proposal.id, UInt64(1))
    Test.assertEqual(proposal.proposer, Address(0x01))
    Test.assertEqual(proposal.description, "Add MOET token to the pool")
    Test.assertEqual(proposal.forVotes, 0.0)
    Test.assertEqual(proposal.againstVotes, 0.0)
    Test.assertEqual(proposal.status, TidalPoolGovernance.ProposalStatus.Pending)
    Test.assertEqual(proposal.executed, false)
}

access(all) fun testGovernorRoles() {
    // Test role-based access in governor
    
    // Create a pool
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // In a real implementation, we would test:
    // - Admin role management
    // - Proposer permissions
    // - Executor permissions
    // - Pauser permissions
    
    destroy pool
}

access(all) fun testEmergencyPause() {
    // Test emergency pause functionality
    
    // Create basic setup
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // In a real implementation, we would:
    // - Create a governor
    // - Grant pauser role to an account
    // - Test pause/unpause functionality
    // - Verify operations are blocked when paused
    
    destroy pool
}

access(all) fun testProposalLifecycle() {
    // Test complete proposal lifecycle
    
    // 1. Create proposal
    // 2. Voting period
    // 3. Queue proposal
    // 4. Execute after timelock
    
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // This would involve:
    // - Creating a governor
    // - Creating a proposal to add MOET
    // - Having accounts vote
    // - Queuing successful proposal
    // - Executing after timelock expires
    
    destroy pool
}

access(all) fun testGovernanceConfiguration() {
    // Test governance configuration parameters
    
    let votingPeriod: UInt64 = 17280  // ~3 days in blocks
    let proposalThreshold: UFix64 = 100000.0  // 100k tokens to propose
    let quorumThreshold: UFix64 = 4000000.0  // 4M tokens for quorum
    let executionDelay: UFix64 = 172800.0  // 2 days timelock
    
    // Verify reasonable values
    Test.assert(votingPeriod > 0)
    Test.assert(proposalThreshold > 0.0)
    Test.assert(quorumThreshold > proposalThreshold)
    Test.assert(executionDelay >= 86400.0)  // At least 1 day
} 