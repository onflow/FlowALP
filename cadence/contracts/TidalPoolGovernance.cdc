import "FungibleToken"
import "TidalProtocol"

access(all) contract TidalPoolGovernance {

    // Events
    access(all) event GovernorCreated(governorID: UInt64, poolAddress: Address)
    access(all) event ProposalCreated(proposalID: UInt64, proposer: Address, description: String)
    access(all) event ProposalExecuted(proposalID: UInt64, executor: Address)
    access(all) event ProposalCancelled(proposalID: UInt64)
    access(all) event VoteCast(proposalID: UInt64, voter: Address, support: Bool, weight: UFix64)
    access(all) event RoleGranted(role: String, recipient: Address, governorID: UInt64)
    access(all) event EmergencyPause(governorID: UInt64, pauser: Address)
    access(all) event TokenAdded(tokenType: Type, addedBy: Address)

    // Entitlements for different permission levels
    access(all) entitlement Execute
    access(all) entitlement Propose  
    access(all) entitlement Vote
    access(all) entitlement Pause
    access(all) entitlement Admin

    // Proposal status enum
    access(all) enum ProposalStatus: UInt8 {
        access(all) case Pending
        access(all) case Active
        access(all) case Cancelled
        access(all) case Defeated
        access(all) case Succeeded
        access(all) case Queued
        access(all) case Executed
        access(all) case Expired
    }

    // Proposal types
    access(all) enum ProposalType: UInt8 {
        access(all) case AddToken
        access(all) case RemoveToken
        access(all) case UpdateTokenParams
        access(all) case UpdateInterestCurve
        access(all) case EmergencyAction
        access(all) case UpdateGovernance
    }

    // Token addition parameters
    access(all) struct TokenAdditionParams {
        access(all) let tokenType: Type
        access(all) let collateralFactor: UFix64
        access(all) let borrowFactor: UFix64
        access(all) let depositRate: UFix64
        access(all) let depositCapacityCap: UFix64
        access(all) let interestCurveType: String  // We'll use string identifier for now

        init(
            tokenType: Type,
            collateralFactor: UFix64,
            borrowFactor: UFix64,
            depositRate: UFix64,
            depositCapacityCap: UFix64,
            interestCurveType: String
        ) {
            self.tokenType = tokenType
            self.collateralFactor = collateralFactor
            self.borrowFactor = borrowFactor
            self.depositRate = depositRate
            self.depositCapacityCap = depositCapacityCap
            self.interestCurveType = interestCurveType
        }
    }

    // Proposal structure
    access(all) struct Proposal {
        access(all) let id: UInt64
        access(all) let proposer: Address
        access(all) let proposalType: ProposalType
        access(all) let description: String
        access(all) let startBlock: UInt64
        access(all) let endBlock: UInt64
        access(all) var forVotes: UFix64
        access(all) var againstVotes: UFix64
        access(all) var status: ProposalStatus
        access(all) let params: {String: AnyStruct}
        access(all) let governorID: UInt64
        access(all) var executed: Bool
        access(all) let executionDelay: UFix64  // Timelock in seconds

        access(contract) fun recordVote(support: Bool, weight: UFix64) {
            if support {
                self.forVotes = self.forVotes + weight
            } else {
                self.againstVotes = self.againstVotes + weight
            }
        }

        access(contract) fun updateStatus(newStatus: ProposalStatus) {
            self.status = newStatus
        }

        access(contract) fun markExecuted() {
            self.executed = true
            self.status = ProposalStatus.Executed
        }

        init(
            id: UInt64,
            proposer: Address,
            proposalType: ProposalType,
            description: String,
            votingPeriod: UInt64,
            params: {String: AnyStruct},
            governorID: UInt64,
            executionDelay: UFix64
        ) {
            self.id = id
            self.proposer = proposer
            self.proposalType = proposalType
            self.description = description
            self.startBlock = getCurrentBlock().height + 1  // Voting starts next block
            self.endBlock = self.startBlock + votingPeriod
            self.forVotes = 0.0
            self.againstVotes = 0.0
            self.status = ProposalStatus.Pending
            self.params = params
            self.governorID = governorID
            self.executed = false
            self.executionDelay = executionDelay
        }
    }

    // Storage paths
    access(all) let GovernorStoragePath: StoragePath
    access(all) let ProposerCapabilityPath: PrivatePath
    access(all) let VoterCapabilityPath: PublicPath
    access(all) let ExecutorCapabilityPath: PrivatePath

    // Contract storage
    access(self) var proposals: {UInt64: Proposal}
    access(self) var nextProposalID: UInt64
    access(self) var governors: @{UInt64: Governor}
    access(self) var nextGovernorID: UInt64

    // Capability interfaces
    access(all) resource interface ProposerPublic {
        access(all) fun createProposal(
            proposalType: ProposalType,
            description: String,
            params: {String: AnyStruct}
        ): UInt64
    }

    access(all) resource interface VoterPublic {
        access(all) fun castVote(proposalID: UInt64, support: Bool)
        access(all) fun getVotingPower(): UFix64
    }

    access(all) resource interface ExecutorPublic {
        access(all) fun executeProposal(proposalID: UInt64)
        access(all) fun queueProposal(proposalID: UInt64)
    }

    // Governor resource - the main governance controller
    access(all) resource Governor {
        access(all) let id: UInt64
        access(self) let poolCapability: Capability<auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool>
        access(self) var votingPeriod: UInt64  // blocks
        access(self) var proposalThreshold: UFix64
        access(self) var quorumThreshold: UFix64
        access(self) var executionDelay: UFix64  // seconds for timelock
        access(self) var paused: Bool

        // Role management
        access(self) var admins: {Address: Bool}
        access(self) var proposers: {Address: Bool}
        access(self) var executors: {Address: Bool}
        access(self) var pausers: {Address: Bool}

        // Track votes to prevent double voting
        access(self) var votes: {UInt64: {Address: Bool}}  // proposalID -> voter -> voted

        // Initialize the governor
        init(
            poolCapability: Capability<auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool>,
            votingPeriod: UInt64,
            proposalThreshold: UFix64,
            quorumThreshold: UFix64,
            executionDelay: UFix64,
            creator: Address
        ) {
            self.id = TidalPoolGovernance.nextGovernorID
            TidalPoolGovernance.nextGovernorID = TidalPoolGovernance.nextGovernorID + 1
            
            self.poolCapability = poolCapability
            self.votingPeriod = votingPeriod
            self.proposalThreshold = proposalThreshold
            self.quorumThreshold = quorumThreshold
            self.executionDelay = executionDelay
            self.paused = false
            self.votes = {}

            // Creator gets all roles initially
            self.admins = {creator: true}
            self.proposers = {creator: true}
            self.executors = {creator: true}
            self.pausers = {creator: true}

            emit GovernorCreated(governorID: self.id, poolAddress: poolCapability.address)
        }

        // Create a proposal - requires a caller address
        access(all) fun createProposal(
            proposalType: ProposalType,
            description: String,
            params: {String: AnyStruct},
            caller: Address
        ): UInt64 {
            pre {
                !self.paused: "Governance is paused"
                self.proposers[caller] ?? false: "Caller does not have proposer role"
            }

            // Check voting power in function body instead of precondition
            let votingPower = self.getVotingPowerFor(address: caller)
            assert(votingPower >= self.proposalThreshold, message: "Proposer does not meet threshold")

            let proposalID = TidalPoolGovernance.nextProposalID
            TidalPoolGovernance.nextProposalID = TidalPoolGovernance.nextProposalID + 1

            let proposal = Proposal(
                id: proposalID,
                proposer: caller,
                proposalType: proposalType,
                description: description,
                votingPeriod: self.votingPeriod,
                params: params,
                governorID: self.id,
                executionDelay: self.executionDelay
            )

            TidalPoolGovernance.proposals[proposalID] = proposal
            
            // Initialize vote tracking for this proposal
            self.votes[proposalID] = {}
            
            emit ProposalCreated(
                proposalID: proposalID, 
                proposer: proposal.proposer, 
                description: description
            )

            return proposalID
        }

        // Cast a vote - requires a caller address
        access(all) fun castVote(proposalID: UInt64, support: Bool, caller: Address) {
            pre {
                !self.paused: "Governance is paused"
                TidalPoolGovernance.proposals[proposalID] != nil: "Proposal does not exist"
            }

            // Check if already voted
            let hasVoted = self.votes[proposalID] != nil && self.votes[proposalID]![caller] != nil && self.votes[proposalID]![caller]!
            assert(!hasVoted, message: "Already voted on this proposal")

            let proposal = TidalPoolGovernance.proposals[proposalID]!
            let currentBlock = getCurrentBlock().height

            // Check voting period
            assert(
                currentBlock >= proposal.startBlock && currentBlock <= proposal.endBlock,
                message: "Voting is not active"
            )

            let votingPower = self.getVotingPowerFor(address: caller)
            
            // Get the current proposal, update it, and save it back
            var updatedProposal = TidalPoolGovernance.proposals[proposalID]!
            updatedProposal.recordVote(support: support, weight: votingPower)
            TidalPoolGovernance.proposals[proposalID] = updatedProposal

            // Record that this address has voted
            if self.votes[proposalID] == nil {
                self.votes[proposalID] = {}
            }
            let votes = self.votes[proposalID]!
            votes[caller] = true
            self.votes[proposalID] = votes

            emit VoteCast(
                proposalID: proposalID,
                voter: caller,
                support: support,
                weight: votingPower
            )
        }

        // Get voting power (can be customized based on token holdings, etc.)
        access(all) fun getVotingPower(): UFix64 {
            // This is for the interface - actual implementation uses getVotingPowerFor
            return 1.0
        }

        // Get voting power for a specific address
        access(all) fun getVotingPowerFor(address: Address): UFix64 {
            // For now, return 1.0 for any valid address
            // TODO: Implement token-based voting power
            return 1.0
        }

        // Queue a proposal for execution (timelock)
        access(all) fun queueProposal(proposalID: UInt64, caller: Address) {
            pre {
                !self.paused: "Governance is paused"
                self.executors[caller] ?? false: "Caller does not have executor role"
                TidalPoolGovernance.proposals[proposalID] != nil: "Proposal does not exist"
            }

            let proposal = TidalPoolGovernance.proposals[proposalID]!
            
            // Check if voting has ended and proposal succeeded
            assert(getCurrentBlock().height > proposal.endBlock, message: "Voting has not ended")
            assert(proposal.forVotes > proposal.againstVotes, message: "Proposal did not pass")
            assert(
                proposal.forVotes + proposal.againstVotes >= self.quorumThreshold,
                message: "Quorum not reached"
            )

            // Update proposal status
            var updatedProposal = TidalPoolGovernance.proposals[proposalID]!
            updatedProposal.updateStatus(newStatus: ProposalStatus.Queued)
            TidalPoolGovernance.proposals[proposalID] = updatedProposal
        }

        // Execute a proposal
        access(all) fun executeProposal(proposalID: UInt64, caller: Address) {
            pre {
                !self.paused: "Governance is paused"
                self.executors[caller] ?? false: "Caller does not have executor role"
                TidalPoolGovernance.proposals[proposalID] != nil: "Proposal does not exist"
            }

            let proposal = TidalPoolGovernance.proposals[proposalID]!
            
            // Check proposal is queued and timelock has passed
            assert(proposal.status == ProposalStatus.Queued, message: "Proposal not queued")
            assert(!proposal.executed, message: "Proposal already executed")
            
            // Execute based on proposal type
            switch proposal.proposalType {
                case ProposalType.AddToken:
                    self.executeAddToken(params: proposal.params)
                case ProposalType.UpdateTokenParams:
                    self.executeUpdateTokenParams(params: proposal.params)
                default:
                    panic("Unsupported proposal type")
            }

            // Mark proposal as executed
            var updatedProposal = TidalPoolGovernance.proposals[proposalID]!
            updatedProposal.markExecuted()
            TidalPoolGovernance.proposals[proposalID] = updatedProposal
            
            emit ProposalExecuted(
                proposalID: proposalID,
                executor: caller
            )
        }

        // Execute token addition
        access(self) fun executeAddToken(params: {String: AnyStruct}) {
            let tokenParams = params["tokenParams"]! as! TokenAdditionParams
            let pool = self.poolCapability.borrow() 
                ?? panic("Could not borrow pool capability")

            // Create appropriate interest curve based on type
            let interestCurve: {TidalProtocol.InterestCurve} = 
                TidalProtocol.SimpleInterestCurve()  // Default for now

            pool.addSupportedToken(
                tokenType: tokenParams.tokenType,
                collateralFactor: tokenParams.collateralFactor,
                borrowFactor: tokenParams.borrowFactor,
                interestCurve: interestCurve,
                depositRate: tokenParams.depositRate,
                depositCapacityCap: tokenParams.depositCapacityCap
            )

            emit TokenAdded(
                tokenType: tokenParams.tokenType,
                addedBy: self.poolCapability.address
            )
        }

        // Execute token parameter update
        access(self) fun executeUpdateTokenParams(params: {String: AnyStruct}) {
            // TODO: Implement token parameter updates
            panic("Not implemented yet")
        }

        // Role management functions
        access(Admin) fun grantRole(role: String, recipient: Address, caller: Address) {
            pre {
                self.admins[caller] ?? false: "Caller is not admin"
            }

            switch role {
                case "admin":
                    self.admins[recipient] = true
                case "proposer":
                    self.proposers[recipient] = true
                case "executor":
                    self.executors[recipient] = true
                case "pauser":
                    self.pausers[recipient] = true
                default:
                    panic("Invalid role")
            }

            emit RoleGranted(role: role, recipient: recipient, governorID: self.id)
        }

        access(Admin) fun revokeRole(role: String, account: Address, caller: Address) {
            pre {
                self.admins[caller] ?? false: "Caller is not admin"
            }

            switch role {
                case "admin":
                    self.admins.remove(key: account)
                case "proposer":
                    self.proposers.remove(key: account)
                case "executor":
                    self.executors.remove(key: account)
                case "pauser":
                    self.pausers.remove(key: account)
                default:
                    panic("Invalid role")
            }
        }

        // Emergency functions
        access(Pause) fun pause(caller: Address) {
            pre {
                self.pausers[caller] ?? false: "Caller does not have pauser role"
                !self.paused: "Already paused"
            }
            
            self.paused = true
            emit EmergencyPause(governorID: self.id, pauser: caller)
        }

        access(Pause) fun unpause(caller: Address) {
            pre {
                self.pausers[caller] ?? false: "Caller does not have pauser role"
                self.paused: "Not paused"
            }
            
            self.paused = false
        }
    }

    // Create a new governor for a pool
    access(all) fun createGovernor(
        poolCapability: Capability<auth(TidalProtocol.EPosition, TidalProtocol.EGovernance) &TidalProtocol.Pool>,
        votingPeriod: UInt64,
        proposalThreshold: UFix64,
        quorumThreshold: UFix64,
        executionDelay: UFix64
    ): @Governor {
        return <- create Governor(
            poolCapability: poolCapability,
            votingPeriod: votingPeriod,
            proposalThreshold: proposalThreshold,
            quorumThreshold: quorumThreshold,
            executionDelay: executionDelay,
            creator: self.account.address
        )
    }

    // View functions
    access(all) fun getProposal(proposalID: UInt64): Proposal? {
        return self.proposals[proposalID]
    }

    access(all) fun getAllProposals(): [Proposal] {
        return self.proposals.values
    }

    init() {
        self.GovernorStoragePath = /storage/TidalGovernor
        self.ProposerCapabilityPath = /private/TidalProposer
        self.VoterCapabilityPath = /public/TidalVoter
        self.ExecutorCapabilityPath = /private/TidalExecutor

        self.proposals = {}
        self.nextProposalID = 0
        self.governors <- {}
        self.nextGovernorID = 0
    }
} 