import "FlowCreditMarket"
import "FlowCreditMarketRebalancerV1"
import "FlowTransactionScheduler"

// FlowCreditMarketRebalancerPaidV1 — Managed rebalancer service for Flow Credit Market positions.
//
// This contract hosts scheduled rebalancers on behalf of users. Instead of users storing and
// configuring Rebalancer resources themselves, they call createPaidRebalancer with a position
// rebalance capability and receive a lightweight RebalancerPaid resource. The contract stores
// the underlying Rebalancer, wires it to the FlowTransactionScheduler, and applies the
// defaultRecurringConfig (interval, priority, txnFunder, etc.).
// The txnFunder set by the admin will be used to fund the rebalance transactions for the users.
// Users can fixReschedule by UUID or delete their RebalancerPaid to stop and remove the rebalancer.
// Admins control the default config and can update or remove individual paid rebalancers.
// See RebalanceArchitecture.md for an architecture overview.
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

    // default recurring config for all newly created paid rebalancers
    // this entails the txnFunder, which will be used to fund the rebalance transactions
    access(all) var defaultRecurringConfig: FlowCreditMarketRebalancerV1.RecurringConfig?
    access(all) var adminStoragePath: StoragePath

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

    access(all) resource Admin {
        // update the default recurring config for all newly created paid rebalancers
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

        access(all) fun borrowAuthorizedRebalancer(
            uuid: UInt64,
        ): auth(FlowCreditMarket.ERebalance, FlowCreditMarketRebalancerV1.Rebalancer.Configure) &FlowCreditMarketRebalancerV1.Rebalancer? {
            return FlowCreditMarketRebalancerPaidV1.borrowRebalancer(uuid: uuid)
        }

        access(all) fun updateRecurringConfig(
            uuid: UInt64,
            recurringConfig: FlowCreditMarketRebalancerV1.RecurringConfig) 
        {
            let rebalancer = FlowCreditMarketRebalancerPaidV1.borrowRebalancer(uuid: uuid)!
            rebalancer.setRecurringConfig(recurringConfig)
        }

        access(account) fun removePaidRebalancer(uuid: UInt64) {
            FlowCreditMarketRebalancerPaidV1.removePaidRebalancer(uuid: uuid)
            emit RemovedRebalancerPaid(uuid: uuid)
        }
    }

    access(all) entitlement Delete

    access(all) resource RebalancerPaid {
        // the UUID of the rebalancer this resource is associated with
        access(all) var rebalancerUUID : UInt64

        init(rebalancerUUID: UInt64) {
            self.rebalancerUUID = rebalancerUUID
        }

        access(Delete) fun delete() {
            FlowCreditMarketRebalancerPaidV1.removePaidRebalancer(uuid: self.rebalancerUUID)
        }

        access(all) fun fixReschedule() {
            FlowCreditMarketRebalancerPaidV1.fixReschedule(uuid: self.rebalancerUUID)
        }
    }

    access(all) fun fixReschedule(
        uuid: UInt64,
    ) {
        let rebalancer = FlowCreditMarketRebalancerPaidV1.borrowRebalancer(uuid: uuid)!
        rebalancer.fixReschedule()
    }

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

    // issue and set the capability that the scheduler will use to call back into this rebalancer
    access(self) fun setSelfCapability(
        uuid: UInt64,
    ) : auth(FlowCreditMarket.ERebalance, FlowCreditMarketRebalancerV1.Rebalancer.Configure) &FlowCreditMarketRebalancerV1.Rebalancer {
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
        return StoragePath(identifier: "FlowCreditMarket.RebalancerV1\(uuid)")!
    }

    init() {
        self.adminStoragePath = StoragePath(identifier: "FlowCreditMarket.RebalancerPaidV1.Admin")!
        self.defaultRecurringConfig = nil
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.adminStoragePath)
    }
}
