import "FlowCreditMarket"
import "FlowCreditMarketRebalancerV1"
import "FlowTransactionScheduler"

// FlowCreditMarketRebalancerPaidV1 — Managed rebalancer service for Flow Credit Market positions.
//
// This contract hosts scheduled rebalancers on behalf of users. Instead of users storing and
// configuring Rebalancer resources themselves, they call createPaidRebalancer with a position
// rebalance capability and receive a lightweight RebalancerPaid resource. The contract stores
// the underlying Rebalancer, wires it to the FlowTransactionScheduler, and applies a shared
// defaultRecurringConfig (interval, priority, txnFunder, etc.). Users can fixReschedule by UUID
// or delete their RebalancerPaid to stop and remove the rebalancer. Admins control the default
// config and can update or remove individual paid rebalancers.
access(all) contract FlowCreditMarketRebalancerPaidV1 {

    access(all) var defaultRecurringConfig: FlowCreditMarketRebalancerV1.RecurringConfig?

    access(all) fun fixReschedule(
        uuid: UInt64,
    ) {
        self.borrowRebalancer(uuid: uuid)!.fixReschedule()
    }

    access(all) fun createPaidRebalancer(
        positionRebalanceCapability: Capability<auth(FlowCreditMarket.Rebalance) &{FlowCreditMarketRebalancerV1.Rebalancable}>,
    ): @RebalancerPaid {
        assert(positionRebalanceCapability.check(), message: "Invalid position rebalance capability")
        let rebalancer <- FlowCreditMarketRebalancerV1.createRebalancer(
            recurringConfig: self.defaultRecurringConfig!, 
            positionRebalanceCapability: positionRebalanceCapability
        )
        let uuid = rebalancer.uuid
        self.storeRebalancer(rebalancer: <-rebalancer)
        self.setSelfCapability(uuid: uuid)
        self.borrowRebalancer(uuid: uuid)!.fixReschedule()
        return <- create RebalancerPaid(rebalancerUUID: uuid)
    }

    access(all) resource Admin {
        access(all) fun updateDefaultRecurringConfig(recurringConfig: FlowCreditMarketRebalancerV1.RecurringConfig) {
            FlowCreditMarketRebalancerPaidV1.defaultRecurringConfig = recurringConfig
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
        }
    }

    access(all) resource RebalancerPaid {
        access(all) var rebalancerUUID : UInt64

        init(rebalancerUUID: UInt64) {
            self.rebalancerUUID = rebalancerUUID
        }

        access(all) fun delete() {
            FlowCreditMarketRebalancerPaidV1.removePaidRebalancer(uuid: self.rebalancerUUID)
        }
    }

    access(self) fun removePaidRebalancer(uuid: UInt64) {
        destroy <- self.account.storage.load<@FlowCreditMarketRebalancerV1.Rebalancer>(from: self.getPath(uuid: uuid))
    }

    access(self) fun storeRebalancer(
        rebalancer: @FlowCreditMarketRebalancerV1.Rebalancer,
    ) {
        let path = self.getPath(uuid: rebalancer.uuid)
        self.account.storage.save(<-rebalancer, to: path)
    }

    access(self) fun borrowRebalancer(
        uuid: UInt64,
    ): auth(FlowCreditMarket.Rebalance, FlowCreditMarketRebalancerV1.Rebalancer.Configure) &FlowCreditMarketRebalancerV1.Rebalancer? {
        return self.account.storage.borrow<auth(FlowCreditMarket.Rebalance, FlowCreditMarketRebalancerV1.Rebalancer.Configure) &FlowCreditMarketRebalancerV1.Rebalancer>(from: self.getPath(uuid: uuid))
    }

    access(self) fun setSelfCapability(
        uuid: UInt64,
    ) {
        let selfCap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(self.getPath(uuid: uuid))
        self.borrowRebalancer(uuid: uuid)!.setSelfCapability(selfCap)
    }

    access(self) view fun getPath(uuid: UInt64): StoragePath {
        return StoragePath(identifier: "FCM.Rebalancer\(uuid)")!
    }

    init() {
        self.defaultRecurringConfig = nil
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: /storage/flowCreditMarketRebalancerPaidV1Admin)
    }
}
