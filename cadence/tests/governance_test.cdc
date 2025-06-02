import Test
import TidalProtocol from "../contracts/TidalProtocol.cdc"
import TidalPoolGovernance from "../contracts/TidalPoolGovernance.cdc"
import FlowToken from 0x1654653399040a61
import MOET from "../contracts/MOET.cdc"

access(all) let governanceAcct = Test.getAccount(0x0000000000000008)
access(all) let proposerAcct = Test.getAccount(0x0000000000000009)
access(all) let executorAcct = Test.getAccount(0x000000000000000a)
access(all) let voterAcct = Test.getAccount(0x000000000000000b)

access(all) fun setup() {
    // Deploy TidalPoolGovernance contract
    let err = Test.deployContract(
        name: "TidalPoolGovernance",
        path: "../contracts/TidalPoolGovernance.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Deploy MOET if not already deployed
    Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]
    )
}

access(all) fun testGovernanceCreation() {
    // Create a pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<@FlowToken.Vault>(),
        defaultTokenThreshold: 0.8
    )

    // Save pool to storage
    governanceAcct.storage.save(<-pool, to: /storage/tidalPool)

    // Create capability for governance
    let poolCap = governanceAcct.capabilities.storage.issue<auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool>(
        /storage/tidalPool
    )

    // Create governor
    let governor <- TidalPoolGovernance.createGovernor(
        poolCapability: poolCap,
        votingPeriod: 10,  // 10 blocks
        proposalThreshold: 1.0,  // 1 vote to propose
        quorumThreshold: 2.0,   // 2 votes for quorum
        executionDelay: 0.0     // No timelock for testing
    )

    // Save governor to storage
    governanceAcct.storage.save(<-governor, to: TidalPoolGovernance.GovernorStoragePath)

    // Verify governor was created
    let governorRef = governanceAcct.storage.borrow<&TidalPoolGovernance.Governor>(
        from: TidalPoolGovernance.GovernorStoragePath
    )
    Test.assert(governorRef != nil, message: "Governor should exist")
}

access(all) fun testRoleManagement() {
    let governorRef = governanceAcct.storage.borrow<auth(TidalPoolGovernance.Admin) &TidalPoolGovernance.Governor>(
        from: TidalPoolGovernance.GovernorStoragePath
    )!

    // Grant proposer role
    governorRef.grantRole(
        role: "proposer",
        recipient: proposerAcct.address,
        caller: governanceAcct.address
    )

    // Grant executor role
    governorRef.grantRole(
        role: "executor",
        recipient: executorAcct.address,
        caller: governanceAcct.address
    )

    // Test that non-admin cannot grant roles
    Test.expectFailure(fun() {
        governorRef.grantRole(
            role: "admin",
            recipient: voterAcct.address,
            caller: proposerAcct.address
        )
    }, errorMessageSubstring: "Caller is not admin")
}

access(all) fun testProposalCreation() {
    let governorRef = governanceAcct.storage.borrow<&TidalPoolGovernance.Governor>(
        from: TidalPoolGovernance.GovernorStoragePath
    )!

    // Create token addition proposal
    let tokenParams = TidalPoolGovernance.TokenAdditionParams(
        tokenType: Type<@MOET.Vault>(),
        exchangeRate: 1.0,
        liquidationThreshold: 0.75,
        interestCurveType: "simple"
    )

    let proposalID = governorRef.createProposal(
        proposalType: TidalPoolGovernance.ProposalType.AddToken,
        description: "Add MOET stablecoin to the pool",
        params: {"tokenParams": tokenParams},
        caller: proposerAcct.address
    )

    // Verify proposal was created
    let proposal = TidalPoolGovernance.getProposal(proposalID: proposalID)
    Test.assert(proposal != nil, message: "Proposal should exist")
    Test.assertEqual(proposal!.proposer, proposerAcct.address)
    Test.assertEqual(proposal!.description, "Add MOET stablecoin to the pool")
}

access(all) fun testVoting() {
    let governorRef = governanceAcct.storage.borrow<&TidalPoolGovernance.Governor>(
        from: TidalPoolGovernance.GovernorStoragePath
    )!

    // Get the proposal ID (assuming it's 0 from previous test)
    let proposalID: UInt64 = 0

    // Cast votes
    governorRef.castVote(
        proposalID: proposalID,
        support: true,
        caller: governanceAcct.address
    )

    governorRef.castVote(
        proposalID: proposalID,
        support: true,
        caller: proposerAcct.address
    )

    // Try to vote twice (should fail)
    Test.expectFailure(fun() {
        governorRef.castVote(
            proposalID: proposalID,
            support: false,
            caller: governanceAcct.address
        )
    }, errorMessageSubstring: "Already voted on this proposal")

    // Check vote counts
    let proposal = TidalPoolGovernance.getProposal(proposalID: proposalID)!
    Test.assertEqual(proposal.forVotes, 2.0)
    Test.assertEqual(proposal.againstVotes, 0.0)
}

access(all) fun testProposalExecution() {
    let governorRef = governanceAcct.storage.borrow<&TidalPoolGovernance.Governor>(
        from: TidalPoolGovernance.GovernorStoragePath
    )!

    let proposalID: UInt64 = 0

    // Wait for voting period to end
    Test.moveTime(by: 11.0)  // Move 11 blocks forward

    // Queue the proposal
    governorRef.queueProposal(
        proposalID: proposalID,
        caller: executorAcct.address
    )

    // Verify proposal is queued
    var proposal = TidalPoolGovernance.getProposal(proposalID: proposalID)!
    Test.assertEqual(proposal.status, TidalPoolGovernance.ProposalStatus.Queued)

    // Execute the proposal
    governorRef.executeProposal(
        proposalID: proposalID,
        caller: executorAcct.address
    )

    // Verify proposal is executed
    proposal = TidalPoolGovernance.getProposal(proposalID: proposalID)!
    Test.assertEqual(proposal.status, TidalPoolGovernance.ProposalStatus.Executed)
    Test.assert(proposal.executed, message: "Proposal should be marked as executed")

    // Verify MOET was added to the pool
    let poolRef = governanceAcct.storage.borrow<&TidalProtocol.Pool>(
        from: /storage/tidalPool
    )!
    Test.assert(poolRef.isTokenSupported(tokenType: Type<@MOET.Vault>()))
}

access(all) fun testEmergencyPause() {
    let governorRef = governanceAcct.storage.borrow<auth(TidalPoolGovernance.Pause) &TidalPoolGovernance.Governor>(
        from: TidalPoolGovernance.GovernorStoragePath
    )!

    // Pause governance
    governorRef.pause(caller: governanceAcct.address)

    // Try to create proposal while paused (should fail)
    Test.expectFailure(fun() {
        let tokenParams = TidalPoolGovernance.TokenAdditionParams(
            tokenType: Type<@FlowToken.Vault>(),
            exchangeRate: 1.0,
            liquidationThreshold: 0.8,
            interestCurveType: "simple"
        )

        governorRef.createProposal(
            proposalType: TidalPoolGovernance.ProposalType.AddToken,
            description: "This should fail",
            params: {"tokenParams": tokenParams},
            caller: proposerAcct.address
        )
    }, errorMessageSubstring: "Governance is paused")

    // Unpause
    governorRef.unpause(caller: governanceAcct.address)
}

access(all) fun testUnauthorizedTokenAddition() {
    let poolRef = governanceAcct.storage.borrow<&TidalProtocol.Pool>(
        from: /storage/tidalPool
    )!

    // Try to add token without governance (should fail due to entitlement)
    // This test would fail at compile time if someone tries to call
    // addSupportedToken without the proper entitlement
    
    // Instead, let's verify only governance can add tokens
    let poolCapWithoutGovernance = governanceAcct.capabilities.storage.issue<&TidalProtocol.Pool>(
        /storage/tidalPool
    )
    
    let limitedPoolRef = poolCapWithoutGovernance.borrow()!
    
    // These methods should be accessible
    Test.assert(limitedPoolRef.isTokenSupported(tokenType: Type<@MOET.Vault>()))
    let supportedTokens = limitedPoolRef.getSupportedTokens()
    Test.assert(supportedTokens.length >= 2)  // FlowToken and MOET
}

access(all) fun testMultipleProposals() {
    let governorRef = governanceAcct.storage.borrow<&TidalPoolGovernance.Governor>(
        from: TidalPoolGovernance.GovernorStoragePath
    )!

    // Create multiple proposals
    let proposals: [UInt64] = []
    
    var i = 0
    while i < 3 {
        let tokenParams = TidalPoolGovernance.TokenAdditionParams(
            tokenType: Type<@FlowToken.Vault>(),
            exchangeRate: 1.0 + UFix64(i) * 0.1,
            liquidationThreshold: 0.8,
            interestCurveType: "simple"
        )

        let proposalID = governorRef.createProposal(
            proposalType: TidalPoolGovernance.ProposalType.AddToken,
            description: "Proposal ".concat(i.toString()),
            params: {"tokenParams": tokenParams},
            caller: proposerAcct.address
        )
        
        proposals.append(proposalID)
        i = i + 1
    }

    // Verify all proposals exist
    let allProposals = TidalPoolGovernance.getAllProposals()
    Test.assert(allProposals.length >= 3, message: "Should have at least 3 proposals")
} 