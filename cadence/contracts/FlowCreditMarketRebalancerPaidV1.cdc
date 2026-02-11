import "FlowCreditMarket"
import "FlowCreditMarketRebalancerV1"
import "FlowTransactionScheduler"

// FlowCreditMarketRebalancerPaidV1 — Managed rebalancer service for Flow Credit Market positions.
//
// Intended for use by the protocol operators only. This contract hosts scheduled rebalancers
// on behalf of users. Instead of users storing and configuring Rebalancer resources themselves,
// they call createPaidRebalancer with a position rebalance capability and receive a lightweight
// RebalancerPaid resource. The contract stores the underlying Rebalancer, wires it to the
// FlowTransactionScheduler, and applies defaultRecurringConfig (interval, priority, txnFunder, etc.).
// The admin's txnFunder in that config is used to pay for rebalance transactions. Users can
// fixReschedule (via their RebalancerPaid) or delete RebalancerPaid to stop. Admins control the
// default config and can update or remove individual paid rebalancers. See RebalanceArchitecture.md.
access(all) contract FlowCreditMarketRebalancerPaidV1 {

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
    /// createPaidRebalancer is used. Includes txnFunder, which pays for scheduled rebalance transactions.
    access(all) var defaultRecurringConfig: FlowCreditMarketRebalancerV1.RecurringConfig?
    access(all) var adminStoragePath: StoragePath

    /// Create a paid rebalancer for the given position. Uses defaultRecurringConfig (must be set).
    /// Returns a RebalancerPaid resource; the underlying Rebalancer is stored in this contract and
    /// the first run is scheduled. Caller should register the returned uuid with a Supervisor.
    access(all) fun createPaidRebalancer(
        positionRebalanceCapability: Capability<auth(FlowCreditMarket.ERebalance) &FlowCreditMarket.Position>,
    ): @RebalancerPaid {
        assert(positionRebalanceCapability.check(), message: "Invalid position rebalance capability")
        let rebalancer <- FlowCreditMarketRebalancerV1.createRebalancer(
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
        /// Set the default RecurringConfig for all newly created paid rebalancers (interval, txnFunder, etc.).
        access(all) fun updateDefaultRecurringConfig(recurringConfig: FlowCreditMarketRebalancerV1.RecurringConfig) {
            FlowCreditMarketRebalancerPaidV1.defaultRecurringConfig = recurringConfig
            emit UpdatedDefaultRecurringConfig(
                interval: recurringConfig.interval,
                priority: recurringConfig.priority.rawValue,
                executionEffort: recurringConfig.executionEffort,
                estimationMargin: recurringConfig.estimationMargin,
                forceRebalance: recurringConfig.forceRebalance,
            )
        }

        /// Borrow a paid rebalancer with Configure and ERebalance auth (e.g. for setRecurringConfig or rebalance).
        access(all) fun borrowAuthorizedRebalancer(
            uuid: UInt64,
        ): auth(FlowCreditMarket.ERebalance, FlowCreditMarketRebalancerV1.Rebalancer.Configure) &FlowCreditMarketRebalancerV1.Rebalancer? {
            return FlowCreditMarketRebalancerPaidV1.borrowRebalancer(uuid: uuid)
        }

        /// Update the RecurringConfig for a specific paid rebalancer (interval, txnFunder, etc.).
        access(all) fun updateRecurringConfig(
            uuid: UInt64,
            recurringConfig: FlowCreditMarketRebalancerV1.RecurringConfig)
        {
            let rebalancer = FlowCreditMarketRebalancerPaidV1.borrowRebalancer(uuid: uuid)!
            rebalancer.setRecurringConfig(recurringConfig)
        }

        /// Remove a paid rebalancer: cancel scheduled transactions (refund to txnFunder) and destroy it.
        access(account) fun removePaidRebalancer(uuid: UInt64) {
            FlowCreditMarketRebalancerPaidV1.removePaidRebalancer(uuid: uuid)
            emit RemovedRebalancerPaid(uuid: uuid)
        }
    }

    access(all) entitlement Delete

    /// User's handle to a paid rebalancer. Allows fixReschedule (recover if scheduling failed) or
    /// delete (stop and remove the rebalancer; caller should also remove from Supervisor).
    access(all) resource RebalancerPaid {
        access(all) var rebalancerUUID: UInt64

        init(rebalancerUUID: UInt64) {
            self.rebalancerUUID = rebalancerUUID
        }

        /// Stop and remove the paid rebalancer; scheduled transactions are cancelled and fees refunded to the admin txnFunder.
        access(Delete) fun delete() {
            FlowCreditMarketRebalancerPaidV1.removePaidRebalancer(uuid: self.rebalancerUUID)
        }

        /// Idempotent: if no next run is scheduled, try to schedule it (e.g. after a transient failure).
        access(all) fun fixReschedule() {
            FlowCreditMarketRebalancerPaidV1.fixReschedule(uuid: self.rebalancerUUID)
        }
    }

    /// Idempotent: for the given paid rebalancer, if there is no scheduled transaction, schedule the next run.
    /// Callable by anyone (e.g. the Supervisor or the RebalancerPaid owner).
    access(all) fun fixReschedule(
        uuid: UInt64,
    ) {
        let rebalancer = FlowCreditMarketRebalancerPaidV1.borrowRebalancer(uuid: uuid)!
        rebalancer.fixReschedule()
    }

    /// Storage path where a user would store their RebalancerPaid for the given uuid (convention for discovery).
    access(all) view fun getPaidRebalancerPath(
        uuid: UInt64,
    ): StoragePath {
        return StoragePath(identifier: "FlowCreditMarket.RebalancerPaidV1_\(self.account.address)_\(uuid)")!
    }

    access(self) fun borrowRebalancer(
        uuid: UInt64,
    ): auth(FlowCreditMarket.ERebalance, FlowCreditMarketRebalancerV1.Rebalancer.Configure) &FlowCreditMarketRebalancerV1.Rebalancer? {
        return self.account.storage.borrow<auth(FlowCreditMarket.ERebalance, FlowCreditMarketRebalancerV1.Rebalancer.Configure) &FlowCreditMarketRebalancerV1.Rebalancer>(from: self.getPath(uuid: uuid))
    }

    access(self) fun removePaidRebalancer(uuid: UInt64) {
        let rebalancer <- self.account.storage.load<@FlowCreditMarketRebalancerV1.Rebalancer>(from: self.getPath(uuid: uuid))
        rebalancer?.cancelAllScheduledTransactions()
        destroy <- rebalancer
    }

    access(self) fun storeRebalancer(
        rebalancer: @FlowCreditMarketRebalancerV1.Rebalancer,
    ) {
        let path = self.getPath(uuid: rebalancer.uuid)
        self.account.storage.save(<-rebalancer, to: path)
    }

    /// Issue a capability to the stored Rebalancer and set it on the Rebalancer so it can pass itself to the scheduler as the execute callback.
    access(self) fun setSelfCapability(
        uuid: UInt64,
    ) : auth(FlowCreditMarket.ERebalance, FlowCreditMarketRebalancerV1.Rebalancer.Configure) &FlowCreditMarketRebalancerV1.Rebalancer {
        let selfCap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(self.getPath(uuid: uuid))
        // Rebalancer is in contract storage; it needs a self-capability to pass to the scheduler when scheduling the next run.
        let rebalancer = self.borrowRebalancer(uuid: uuid)!
        rebalancer.setSelfCapability(selfCap)
        return rebalancer
    }

    access(self) view fun getPath(uuid: UInt64): StoragePath {
        return StoragePath(identifier: "FlowCreditMarket.RebalancerV1\(uuid)")!
    }

    init() {
        self.adminStoragePath = StoragePath(identifier: "FlowCreditMarket.RebalancerPaidV1.Admin")!
        self.defaultRecurringConfig = nil
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.adminStoragePath)
    }
}
