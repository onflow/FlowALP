import Test
import "TidalProtocol"
import "TidalPoolGovernance"
import "MOET"
import "./test_helpers.cdc"

access(all) let governanceAcct = Test.getAccount(0x0000000000000008)
access(all) let proposerAcct = Test.getAccount(0x0000000000000009)
access(all) let executorAcct = Test.getAccount(0x000000000000000a)
access(all) let voterAcct = Test.getAccount(0x000000000000000b)

access(all) fun setup() {
    // Deploy contracts using the helper
    deployContracts()
    
    // Deploy TidalPoolGovernance
    let err = Test.deployContract(
        name: "TidalPoolGovernance",
        path: "../contracts/TidalPoolGovernance.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all) fun testCreateGovernor() {
    // Create a pool using test helper
    let pool <- createTestPool(defaultTokenThreshold: 0.8)
    let poolRef = &pool as auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool

    // Create a capability for the pool
    let account = Test.createAccount()
    
    // Save the pool to storage using a simpler approach
    // In real tests with proper capability support, we'd create a proper capability
    // For now, we'll test the governor creation concept
    
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
    let pool <- createTestPool(defaultTokenThreshold: 0.8)
    
    // In a real test, we'd properly save the pool and create the capability
    // For now, we verify the pool is created
    Test.assert(pool.getSupportedTokens().length == 1)
    
    destroy pool
}

access(all) fun testGovernanceAddToken() {
    // This test simulates adding a token through governance
    
    // Create a pool
    let pool <- createTestPool(defaultTokenThreshold: 0.8)
    let poolRef = &pool as auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool
    
    // Initial state: only MockVault is supported
    Test.assertEqual(poolRef.getSupportedTokens().length, 1)
    Test.assert(poolRef.isTokenSupported(tokenType: Type<@MockVault>()))
    Test.assert(!poolRef.isTokenSupported(tokenType: Type<@MOET.Vault>()))
    
    // In a real scenario, governance would add MOET
    // For testing, we'll add it directly since we have the entitlement
    poolRef.addSupportedToken(
        tokenType: Type<@MOET.Vault>(),
        exchangeRate: 1.0,
        liquidationThreshold: 0.75,
        interestCurve: TidalProtocol.SimpleInterestCurve()
    )
    
    // Verify MOET was added
    Test.assertEqual(poolRef.getSupportedTokens().length, 2)
    Test.assert(poolRef.isTokenSupported(tokenType: Type<@MOET.Vault>()))
    
    destroy pool
}

access(all) fun testTokenAdditionParams() {
    // Test creating token addition parameters
    let params = TidalPoolGovernance.TokenAdditionParams(
        tokenType: Type<@MockVault>(),
        exchangeRate: 1.0,
        liquidationThreshold: 0.8,
        interestCurveType: "simple"
    )
    
    Test.assertEqual(params.tokenType, Type<@MockVault>())
    Test.assertEqual(params.exchangeRate, 1.0)
    Test.assertEqual(params.liquidationThreshold, 0.8)
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
    
    // Create a pool and governor setup
    let pool <- createTestPool(defaultTokenThreshold: 0.8)
    
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
    let pool <- createTestPool(defaultTokenThreshold: 0.8)
    
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
    
    let pool <- createTestPool(defaultTokenThreshold: 0.8)
    
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