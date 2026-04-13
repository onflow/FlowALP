import "FungibleToken"
import "FungibleTokenMetadataViews"

import "DeFiActionsUtils"
import "DeFiActions"
import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"

import "MOET"
import "FlowToken"

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// THIS IS A TESTING CONTRACT THAT SHOULD NOT BE USED IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// AdversarialReentrancyConnectors
///
/// This contract holds malicious DeFi connectors which implement re-entrancy attacks.
///
/// VaultSourceHacked — malicious topUpSource.
///   When the pool calls withdrawAvailable() during withdrawAndPull, the source
///   immediately calls position.withdraw() on the same pid while the position
///   lock is already held. This tests that the reentrancy guard blocks the
///   inner call and reverts the entire transaction.
///
/// VaultSinkHacked — malicious drawDownSink.
///   When the pool calls depositCapacity() during a rebalance/drawdown push,
///   the sink immediately calls position.depositAndPush() on the same pid
///   while the position lock is already held. This tests that the reentrancy
///   guard blocks the inner call and reverts the entire transaction.
///
/// Both connectors share the LiveData resource to store the manager cap and
/// pid needed for the re-entrant call.
access(all) contract AdversarialReentrancyConnectors {

    // =========================================================================
    // VaultSinkHacked — malicious DeFiActions.Sink
    //
    // When depositCapacity() is called by the pool during a rebalance /
    // drawdown push, this sink attempts a re-entrant position.depositAndPush()
    // on the same pid while the position lock is held.
    // Expected result: lockPosition panics with "Reentrancy: position X is locked"
    // and the entire outer transaction reverts.
    // =========================================================================
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
        access(all) let liveDataCap: Capability<&LiveData>

        init(
            max: UFix64?,
            depositVault: Capability<&{FungibleToken.Vault}>,
            uniqueID: DeFiActions.UniqueIdentifier?,
            liveDataCap: Capability<&LiveData>
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
            self.liveDataCap = liveDataCap
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
            log("VaultSinkHacked.depositCapacity called with balance: \(from.balance)")
            log("liveDataCap valid: \(self.liveDataCap.check())")

            let liveData = self.liveDataCap.borrow() ?? panic("cant borrow LiveData")
            let manager  = liveData.positionManagerCap!.borrow() ?? panic("cant borrow PositionManager")
            let position = manager.borrowAuthorizedPosition(pid: liveData.recursivePositionID!)

            // Attempt re-entrant deposit via Position — must fail due to position lock.
            // We create a small empty MOET vault as the re-entrant deposit payload.
            // The point is not the vault contents but the call itself hitting the lock.
            let reentrantVault <- MOET.createEmptyVault(vaultType: Type<@MOET.Vault>())
            log("Attempting re-entrant depositAndPush (should not succeed)")
            position.depositAndPush(
                from: <-reentrantVault,
                pushToDrawDownSink: false
            )
            log("Re-entrant depositAndPush succeeded (should not reach here)")

            // Normal sink behaviour
            let minimumCapacity = self.minimumCapacity()
            if !self.depositVault.check() || minimumCapacity == 0.0 {
                return
            }
            // deposit the lesser of the originating vault balance and minimum capacity
            let capacity = minimumCapacity <= from.balance ? minimumCapacity : from.balance
            self.depositVault.borrow()!.deposit(from: <-from.withdraw(amount: capacity))
        }
    }

    // =========================================================================
    // LiveData — shared mutable resource used by both hacked connectors.
    // Stores the PositionManager capability and target pid, injected after
    // position creation via setRecursivePosition().
    // =========================================================================
    access(all) resource LiveData {
        /// Capability to the attacker's PositionManager for the recursive call
        access(all) var positionManagerCap: Capability<auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>?
        /// Position ID targeted by the recursive call
        access(all) var recursivePositionID: UInt64?

        init() {
            self.recursivePositionID = nil
            self.positionManagerCap = nil
        }
        access(all) fun setRecursivePosition(
            managerCap: Capability<auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>,
            pid: UInt64
        ) {
            self.positionManagerCap = managerCap
            self.recursivePositionID = pid
        }
    }
    access(all) fun createLiveData(): @LiveData {
        return <- create LiveData()
    }

    // =========================================================================
    // VaultSourceHacked — malicious DeFiActions.Source
    //
    // When withdrawAvailable() is called by the pool during withdrawAndPull,
    // this source attempts a re-entrant position.withdraw() on the same pid
    // while the position lock is held.
    // Expected result: lockPosition panics with "Reentrancy: position X is locked"
    // and the entire outer transaction reverts.
    // =========================================================================
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
            log("VaultSourceHacked.withdrawAvailable called with maxAmount: \(maxAmount)")
            log("=====Recursive position manager: \(self.liveDataCap.check())")
            let liveData = self.liveDataCap.borrow() ?? panic("cant borrow LiveData")
            let manager = liveData.positionManagerCap!.borrow() ?? panic("cant borrow PositionManager")
            let position = manager.borrowAuthorizedPosition(pid: liveData.recursivePositionID!)
            // Attempt reentrant withdrawal via Position (should fail due to position lock)
            let recursiveVault <- position.withdraw(
                type: Type<@FlowToken.Vault>(),
                amount: 900.0
            )
            log("Recursive withdraw succeeded with balance: \(recursiveVault.balance) (should not reach here)")
            destroy recursiveVault

            // Normal vault withdrawal
            let available = self.minimumAvailable()
            if !self.withdrawVault.check() || available == 0.0 || maxAmount == 0.0 {
                panic("Withdraw vault check failed")
            }
            // take the lesser between the available and maximum requested amount
            let withdrawalAmount = available <= maxAmount ? available : maxAmount
            return <- self.withdrawVault.borrow()!.withdraw(amount: withdrawalAmount)
        }
    }
}
