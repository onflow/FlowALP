import "FlowALPv0"
import "FlowALPRebalancerv1"
import "FlowTransactionScheduler"

// FlowALPRebalancerPaidv1 — Managed rebalancer service for Flow ALP positions.
//
// Intended for use by the protocol operators only. This contract hosts scheduled rebalancers
// on behalf of users. Instead of users storing and configuring Rebalancer resources themselves,
// they call createPaidRebalancer with a position rebalance capability and receive a lightweight
// RebalancerPaid resource. The contract stores the underlying Rebalancer, wires it to the
// FlowTransactionScheduler, and applies defaultRecurringConfig (interval, priority, txFunder, etc.).
// The admin's txFunder in that config is used to pay for rebalance transactions. Users can
// fixReschedule (via their RebalancerPaid) or delete RebalancerPaid to stop. Admins control the
// default config and can update or remove individual paid rebalancers. See RebalanceArchitecture.md.
access(all) contract FlowALPRebalancerPaidv1 {

    access(all) event CreatedRebalancerPaid(uuid: UInt64)
    access(all) event RemovedRebalancerPaid(uuid: UInt64)
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

    /// Create a paid rebalancer for the given position. Uses defaultRecurringConfig (must be set).
    /// Returns a RebalancerPaid resource; the underlying Rebalancer is stored in this contract and
    /// the first run is scheduled. Caller should register the returned uuid with a Supervisor.
    access(all) fun createPaidRebalancer(
        positionRebalanceCapability: Capability<auth(FlowALPv0.ERebalance) &FlowALPv0.Position>,
    ): @RebalancerPaid {
        assert(positionRebalanceCapability.check(), message: "Invalid position rebalance capability")
        let rebalancer <- FlowALPRebalancerv1.createRebalancer(
            recurringConfig: self.defaultRecurringConfig!,
            positionRebalanceCapability: positionRebalanceCapability
        )
        let uuid = rebalancer.uuid
        self.storeRebalancer(rebalancer: <-rebalancer)
        self.setSelfCapability(uuid: uuid).fixReschedule()
        emit CreatedRebalancerPaid(uuid: uuid)
        return <- create RebalancerPaid(rebalancerUUID: uuid)
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
            uuid: UInt64,
        ): auth(FlowALPv0.ERebalance, FlowALPRebalancerv1.Rebalancer.Configure) &FlowALPRebalancerv1.Rebalancer? {
            return FlowALPRebalancerPaidv1.borrowRebalancer(uuid: uuid)
        }

        /// Update the RecurringConfig for a specific paid rebalancer (interval, txFunder, etc.).
        access(all) fun updateRecurringConfig(
            uuid: UInt64,
            recurringConfig: {FlowALPRebalancerv1.RecurringConfig})
        {
            let rebalancer = FlowALPRebalancerPaidv1.borrowRebalancer(uuid: uuid)!
            rebalancer.setRecurringConfig(recurringConfig)
        }

        /// Remove a paid rebalancer: cancel scheduled transactions (refund to txFunder) and destroy it.
        access(account) fun removePaidRebalancer(uuid: UInt64) {
            FlowALPRebalancerPaidv1.removePaidRebalancer(uuid: uuid)
            emit RemovedRebalancerPaid(uuid: uuid)
        }
    }

    access(all) entitlement Delete

    /// User's handle to a paid rebalancer. Allows fixReschedule (recover if scheduling failed) or
    /// delete (stop and remove the rebalancer; caller should also remove from Supervisor).
    access(all) resource RebalancerPaid {
        // the UUID of the rebalancer this resource is associated with
        access(all) var rebalancerUUID : UInt64

        init(rebalancerUUID: UInt64) {
            self.rebalancerUUID = rebalancerUUID
        }

        /// Stop and remove the paid rebalancer; scheduled transactions are cancelled and fees refunded to the admin txFunder.
        access(Delete) fun delete() {
            FlowALPRebalancerPaidv1.removePaidRebalancer(uuid: self.rebalancerUUID)
        }

        /// Idempotent: if no next run is scheduled, try to schedule it (e.g. after a transient failure).
        access(all) fun fixReschedule() {
            FlowALPRebalancerPaidv1.fixReschedule(uuid: self.rebalancerUUID)
        }
    }

    /// Idempotent: for the given paid rebalancer, if there is no scheduled transaction, schedule the next run.
    /// Callable by anyone (e.g. the Supervisor or the RebalancerPaid owner).
    access(all) fun fixReschedule(
        uuid: UInt64,
    ) {
        let rebalancer = FlowALPRebalancerPaidv1.borrowRebalancer(uuid: uuid)!
        rebalancer.fixReschedule()
    }

    /// Storage path where a user would store their RebalancerPaid for the given uuid (convention for discovery).
    access(all) view fun getPaidRebalancerPath(
        uuid: UInt64,
    ): StoragePath {
        return StoragePath(identifier: "FlowALP.RebalancerPaidv1_\(self.account.address)_\(uuid)")!
    }

    access(self) fun borrowRebalancer(
        uuid: UInt64,
    ): auth(FlowALPv0.ERebalance, FlowALPRebalancerv1.Rebalancer.Configure) &FlowALPRebalancerv1.Rebalancer? {
        return self.account.storage.borrow<auth(FlowALPv0.ERebalance, FlowALPRebalancerv1.Rebalancer.Configure) &FlowALPRebalancerv1.Rebalancer>(from: self.getPath(uuid: uuid))
    }

    access(self) fun removePaidRebalancer(uuid: UInt64) {
        let rebalancer <- self.account.storage.load<@FlowALPRebalancerv1.Rebalancer>(from: self.getPath(uuid: uuid))
        rebalancer?.cancelAllScheduledTransactions()
        destroy <- rebalancer
    }

    access(self) fun storeRebalancer(
        rebalancer: @FlowALPRebalancerv1.Rebalancer,
    ) {
        let path = self.getPath(uuid: rebalancer.uuid)
        self.account.storage.save(<-rebalancer, to: path)
    }

    /// Issue a capability to the stored Rebalancer and set it on the Rebalancer so it can pass itself to the scheduler as the execute callback.
    access(self) fun setSelfCapability(
        uuid: UInt64,
    ) : auth(FlowALPv0.ERebalance, FlowALPRebalancerv1.Rebalancer.Configure) &FlowALPRebalancerv1.Rebalancer {
        let selfCap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(self.getPath(uuid: uuid))
        // The Rebalancer is stored in the contract storage (storeRebalancer),
        // it needs a capability pointing to itself to pass to the scheduler.
        // We issue this capability here and set it on the Rebalancer, so that when
        // fixReschedule is called, the Rebalancer can pass it to the transaction scheduler
        // as a callback for executing scheduled rebalances.
        let rebalancer = self.borrowRebalancer(uuid: uuid)!
        rebalancer.setSelfCapability(selfCap)
        return rebalancer
    }

    access(self) view fun getPath(uuid: UInt64): StoragePath {
        return StoragePath(identifier: "FlowALP.RebalancerPaidv1\(uuid)")!
    }

    init() {
        self.adminStoragePath = StoragePath(identifier: "FlowALP.RebalancerPaidv1.Admin")!
        self.defaultRecurringConfig = nil
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.adminStoragePath)
    }
}
