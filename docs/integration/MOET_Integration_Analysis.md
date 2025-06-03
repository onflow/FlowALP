# MOET Stablecoin Integration Analysis

## Current Implementation Status

### What's Implemented on `gio/add-stablecoin` Branch

1. **MOET Contract** (`cadence/contracts/MOET.cdc`)
   - ✅ Implements FungibleToken standard
   - ✅ Has minting capabilities through `Minter` resource
   - ✅ Proper metadata implementation
   - ⚠️ Currently just a mock implementation (as noted in contract comments)
   - ❌ No CDP (Collateralized Debt Position) functionality yet
   - ❌ No stability mechanism or oracle integration

### Current Issues

1. **Separation of Concerns**
   - ✅ Good: MOET is a separate contract, not embedded in TidalProtocol
   - ⚠️ Issue: No clear CDP mechanism separate from the lending pool
   - ⚠️ Issue: The minting is centralized through admin-controlled `Minter`

2. **Integration with TidalProtocol**
   - ❌ MOET is imported but not properly integrated
   - ❌ Hardcoded MOET reference in `TidalProtocolSource.withdrawAvailable`
   - ❌ No proper mechanism to add MOET to lending pools

## Implementation Completed on New Branch

### Branch: `feature/moet-stablecoin-integration`

1. **Added Token Management to Pool**
   ```cadence
   access(EGovernance) fun addSupportedToken(
       tokenType: Type, 
       exchangeRate: UFix64, 
       liquidationThreshold: UFix64,
       interestCurve: {InterestCurve}
   )
   ```

2. **Fixed Issues**
   - ✅ Added proper token registration mechanism
   - ✅ Fixed hardcoded MOET reference in withdrawAvailable
   - ✅ Created comprehensive test suite for MOET integration
   - ✅ Implemented complete governance system

3. **Governance Implementation**

### Comprehensive Governance System

#### Cadence-Specific Advantages Leveraged

1. **Resource-Based Governance**
   - Governor is a resource that cannot be duplicated
   - Ownership tracked through resource storage
   - No reentrancy issues by design

2. **Capability-Based Access Control**
   ```cadence
   // Different entitlements for different permission levels
   access(all) entitlement Execute
   access(all) entitlement Propose  
   access(all) entitlement Vote
   access(all) entitlement Pause
   access(all) entitlement Admin
   ```

3. **Path-Based Security**
   - Different storage paths for different access levels
   - No need for complex role mappings like Solidity

#### Key Governance Features

1. **Role-Based Access Control**
   - Admin: Can grant/revoke roles
   - Proposer: Can create proposals
   - Executor: Can execute passed proposals
   - Pauser: Can pause governance in emergencies

2. **Proposal System**
   ```cadence
   access(all) enum ProposalType: UInt8 {
       access(all) case AddToken
       access(all) case RemoveToken
       access(all) case UpdateTokenParams
       access(all) case UpdateInterestCurve
       access(all) case EmergencyAction
       access(all) case UpdateGovernance
   }
   ```

3. **Voting Mechanism**
   - Configurable voting period
   - Proposal threshold requirement
   - Quorum requirement
   - Vote tracking to prevent double voting

4. **Timelock Functionality**
   - Configurable execution delay
   - Queue system for approved proposals

5. **Emergency Controls**
   - Pause/unpause functionality
   - Role-based emergency access

#### Usage Example

```cadence
// 1. Pool creator sets up governance
let pool <- TidalProtocol.createPool(
    defaultToken: Type<@FlowToken.Vault>(),
    defaultTokenThreshold: 0.8
)

// Save pool and create governance capability
account.storage.save(<-pool, to: /storage/tidalPool)
let poolCap = account.capabilities.storage.issue<
    auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool
>(/storage/tidalPool)

// Create governor
let governor <- TidalPoolGovernance.createGovernor(
    poolCapability: poolCap,
    votingPeriod: 17280,      // ~2 days at 12s blocks
    proposalThreshold: 100.0,  // 100 governance tokens to propose
    quorumThreshold: 10000.0,  // 10k votes for quorum
    executionDelay: 86400.0    // 24 hour timelock
)

// 2. Grant roles
governor.grantRole(role: "proposer", recipient: proposerAddress, caller: adminAddress)
governor.grantRole(role: "executor", recipient: executorAddress, caller: adminAddress)

// 3. Create proposal to add MOET
let tokenParams = TidalPoolGovernance.TokenAdditionParams(
    tokenType: Type<@MOET.Vault>(),
    exchangeRate: 1.0,
    liquidationThreshold: 0.75,
    interestCurveType: "stable"
)

let proposalID = governor.createProposal(
    proposalType: ProposalType.AddToken,
    description: "Add MOET stablecoin with $1 peg",
    params: {"tokenParams": tokenParams},
    caller: proposerAddress
)

// 4. Vote on proposal
governor.castVote(proposalID: proposalID, support: true, caller: voterAddress)

// 5. After voting period, queue and execute
governor.queueProposal(proposalID: proposalID, caller: executorAddress)
// Wait for timelock...
governor.executeProposal(proposalID: proposalID, caller: executorAddress)
```

## Security Considerations

1. **Access Control**: Only governance can add tokens via entitlement system
2. **Timelock**: Configurable delay prevents rushed changes
3. **Emergency Pause**: Can halt governance if needed
4. **Role Separation**: Different roles for proposing vs executing
5. **Vote Tracking**: Prevents double voting and ensures fair governance

## Comparison with Solidity Governance

### Cadence Advantages
- No proxy patterns needed
- Resources prevent reentrancy
- Built-in capability system
- No gas optimization concerns
- Cleaner permission model

### Solidity Features We Don't Need
- Complex storage patterns
- Delegate call mechanisms
- Storage collision concerns
- Gas optimization tricks

## Next Steps

1. **Immediate (Tracer Bullet)** ✅
   - Basic MOET integration as borrowable token
   - Full governance system implementation
   - Test suite demonstrating functionality

2. **Short Term**
   - Implement governance token for voting power
   - Add more proposal types
   - Create UI for governance interaction
   - Deploy and test on testnet

3. **Long Term**
   - Implement vote delegation
   - Add governance token staking
   - Create treasury management
   - Implement optimistic governance

## Testing

```bash
# Run governance tests
flow test --cover cadence/tests/governance_test.cdc

# Run MOET integration tests
flow test --cover cadence/tests/moet_integration_test.cdc
``` 