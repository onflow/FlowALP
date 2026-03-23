import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"
import "FlowALPRebalancerv1"
import "FlowTransactionScheduler"

// FlowALPRebalancerPaidv1 — Managed rebalancer service for Flow ALP positions.
//
// This contract hosts scheduled rebalancers on behalf of users. Anyone may call createPaidRebalancer
// (permissionless): pass a position rebalance capability and receive a lightweight RebalancerPaid
// resource. The contract stores the underlying Rebalancer, wires it to the FlowTransactionScheduler,
// and applies defaultRecurringConfig (interval, priority, txFunder, etc.).
// The admin's txFunder is used to pay for rebalance transactions. We rely on 2 things to limit how funds
// can be spent indirectly by used by creating rebalancers in this way:
// 1. This contract enforces that only one rebalancer can be created per position.
// 2. FlowALP enforces a minimum economic value per position.
// Users can fixReschedule (via their RebalancerPaid) or delete RebalancerPaid to stop. Admins control the default config and can update or remove individual paid rebalancers. See RebalanceArchitecture.md.
access(all) contract FlowALPRebalancerPaidv1 {

    access(all) event CreatedRebalancerPaid(positionID: UInt64)
    access(all) event RemovedRebalancerPaid(positionID: UInt64)
    access(all) event UpdatedDefaultRecurringConfig(
        interval: UInt64,
        priority: UInt8,
        executionEffort: UInt64,
        estimationMargin: UFix64,
        forceRebalance: Bool,
    )

    /// Default RecurringConfig for all newly created paid rebalancers. Must be set by Admin before
    /// createPaidRebalancer is used. Includes txFunder, which pays for scheduled rebalance transactions.
    access(all) var defaultRecurringConfig: {FlowALPRebalancerv1.RecurringConfig}?
    access(all) var adminStoragePath: StoragePath

    /// Create a paid rebalancer for the given position. Permissionless: anyone may call this.
    /// Uses defaultRecurringConfig (must be set by Admin). Returns a RebalancerPaid resource; the
    /// underlying Rebalancer is stored in this contract and the first run is scheduled. Caller should
    /// register the returned positionID with a Supervisor.
    access(all) fun createPaidRebalancer(
        positionRebalanceCapability: Capability<auth(FlowALPModels.ERebalance) &FlowALPPositionResources.Position>,
    ): @RebalancerPaid {
        assert(positionRebalanceCapability.check(), message: "Invalid position rebalance capability")
        let positionID = positionRebalanceCapability.borrow()!.id
        let rebalancer <- FlowALPRebalancerv1.createRebalancer(
            recurringConfig: self.defaultRecurringConfig!,
            positionRebalanceCapability: positionRebalanceCapability
        )
        // will panic if the rebalancer already exists
        self.storeRebalancer(rebalancer: <-rebalancer, positionID: positionID)
        self.setSelfCapability(positionID: positionID).fixReschedule()
        emit CreatedRebalancerPaid(positionID: positionID)
        return <- create RebalancerPaid(positionID: positionID)
    }

    /// Admin resource: controls default config and per-rebalancer config; can remove paid rebalancers.
    access(all) resource Admin {
        /// Set the default RecurringConfig for all newly created paid rebalancers (interval, txFunder, etc.).
        access(all) fun updateDefaultRecurringConfig(recurringConfig: {FlowALPRebalancerv1.RecurringConfig}) {
            FlowALPRebalancerPaidv1.defaultRecurringConfig = recurringConfig
            emit UpdatedDefaultRecurringConfig(
                interval: recurringConfig.getInterval(),
                priority: recurringConfig.getPriority().rawValue,
                executionEffort: recurringConfig.getExecutionEffort(),
                estimationMargin: recurringConfig.getEstimationMargin(),
                forceRebalance: recurringConfig.getForceRebalance(),
            )
        }

        /// Borrow a paid rebalancer with Configure and ERebalance auth (e.g. for setRecurringConfig or rebalance).
        access(all) fun borrowAuthorizedRebalancer(
            positionID: UInt64,
        ): auth(FlowALPModels.ERebalance, FlowALPRebalancerv1.Rebalancer.Configure) &FlowALPRebalancerv1.Rebalancer? {
            return FlowALPRebalancerPaidv1.borrowRebalancer(positionID: positionID)
        }

        /// Update the RecurringConfig for a specific paid rebalancer (interval, txFunder, etc.).
        access(all) fun updateRecurringConfig(
            positionID: UInt64,
            recurringConfig: {FlowALPRebalancerv1.RecurringConfig})
        {
            let rebalancer = FlowALPRebalancerPaidv1.borrowRebalancer(positionID: positionID)!
            rebalancer.setRecurringConfig(recurringConfig)
        }

        /// Remove a paid rebalancer: cancel scheduled transactions (refund to txFunder) and destroy it.
        access(account) fun removePaidRebalancer(positionID: UInt64) {
            FlowALPRebalancerPaidv1.removePaidRebalancer(positionID: positionID)
            emit RemovedRebalancerPaid(positionID: positionID)
        }
    }

    access(all) entitlement Delete

    /// User's handle to a paid rebalancer. Allows fixReschedule (recover if scheduling failed) or
    /// delete (stop and remove the rebalancer; caller should also remove from Supervisor).
    access(all) resource RebalancerPaid {
        /// The position id (from positionRebalanceCapability) this paid rebalancer is associated with.
        access(all) var positionID: UInt64

        init(positionID: UInt64) {
            self.positionID = positionID
        }

        /// Stop and remove the paid rebalancer; scheduled transactions are cancelled and fees refunded to the admin txFunder.
        access(Delete) fun delete() {
            FlowALPRebalancerPaidv1.removePaidRebalancer(positionID: self.positionID)
        }

        /// Idempotent: if no next run is scheduled, try to schedule it (e.g. after a transient failure).
        access(all) fun fixReschedule() {
            let _ = FlowALPRebalancerPaidv1.fixReschedule(positionID: self.positionID)
        }
    }

    /// Idempotent: for the given paid rebalancer, if there is no scheduled transaction, schedule the next run.
    /// Callable by anyone (e.g. the Supervisor or the RebalancerPaid owner).
    /// Returns true if the rebalancer was found and processed, false if the UUID is stale (rebalancer no longer exists).
    access(all) fun fixReschedule(
        positionID: UInt64,
    ): Bool {
        if let rebalancer = FlowALPRebalancerPaidv1.borrowRebalancer(positionID: positionID) {
            rebalancer.fixReschedule()
            return true
        }
        return false
    }

    /// Storage path where a user would store their RebalancerPaid for the given position (convention for discovery).
    access(all) view fun getPaidRebalancerPath(
        positionID: UInt64,
    ): StoragePath {
        return StoragePath(identifier: "FlowALP.RebalancerPaidv1_\(self.account.address)_\(positionID)")!
    }

    access(self) fun borrowRebalancer(
        positionID: UInt64,
    ): auth(FlowALPModels.ERebalance, FlowALPRebalancerv1.Rebalancer.Configure) &FlowALPRebalancerv1.Rebalancer? {
        return self.account.storage.borrow<auth(FlowALPModels.ERebalance, FlowALPRebalancerv1.Rebalancer.Configure) &FlowALPRebalancerv1.Rebalancer>(from: self.getPath(positionID: positionID))
    }

    access(self) fun removePaidRebalancer(positionID: UInt64) {
        let rebalancer <- self.account.storage.load<@FlowALPRebalancerv1.Rebalancer>(from: self.getPath(positionID: positionID))
        rebalancer?.cancelAllScheduledTransactions()
        destroy <- rebalancer
    }

    access(self) fun storeRebalancer(
        rebalancer: @FlowALPRebalancerv1.Rebalancer,
        positionID: UInt64,
    ) {
        let path = self.getPath(positionID: positionID)
        if self.account.storage.borrow<&FlowALPRebalancerv1.Rebalancer>(from: path) != nil {
            panic("rebalancer already exists")
        }
        self.account.storage.save(<-rebalancer, to: path)
    }

    /// Issue a capability to the stored Rebalancer and set it on the Rebalancer so it can pass itself to the scheduler as the execute callback.
    access(self) fun setSelfCapability(
        positionID: UInt64,
    ) : auth(FlowALPModels.ERebalance, FlowALPRebalancerv1.Rebalancer.Configure) &FlowALPRebalancerv1.Rebalancer {
        let selfCap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(self.getPath(positionID: positionID))
        // The Rebalancer is stored in the contract storage (storeRebalancer),
        // it needs a capability pointing to itself to pass to the scheduler.
        // We issue this capability here and set it on the Rebalancer, so that when
        // fixReschedule is called, the Rebalancer can pass it to the transaction scheduler
        // as a callback for executing scheduled rebalances.
        let rebalancer = self.borrowRebalancer(positionID: positionID)!
        rebalancer.setSelfCapability(selfCap)
        return rebalancer
    }

    access(self) view fun getPath(positionID: UInt64): StoragePath {
        return StoragePath(identifier: "FlowALP.RebalancerPaidv1\(positionID)")!
    }

    init() {
        self.adminStoragePath = StoragePath(identifier: "FlowALP.RebalancerPaidv1.Admin")!
        self.defaultRecurringConfig = nil
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.adminStoragePath)
    }
}
