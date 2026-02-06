import "FlowTransactionScheduler"
import "FlowCreditMarketRebalancerPaidV1"

access(all) contract FlowCreditMarketSupervisorV1 {

    access(all) event Executed(id: UInt64)

    access(all) resource Supervisor: FlowTransactionScheduler.TransactionHandler {

        access(all) let rebalancers: {UInt64: Bool}

        init() {
            self.rebalancers = {}
        }

        access(all) fun addPaidRebalancer(uuid: UInt64) {
            self.rebalancers[uuid] = true
        }

        access(all) fun removePaidRebalancer(uuid: UInt64): Bool? {
            return self.rebalancers.remove(key: uuid)
        }

        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            emit Executed(id: id)
            for rebalancerUUID in self.rebalancers.keys {
                FlowCreditMarketRebalancerPaidV1.fixReschedule(uuid: rebalancerUUID)
            }
        }
    }

    access(all) fun createSupervisor(): @Supervisor {
        return <- create Supervisor()
    }
}