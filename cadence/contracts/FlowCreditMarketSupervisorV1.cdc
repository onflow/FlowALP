import "FlowTransactionScheduler"
import "FlowCreditMarketRebalancerPaidV1"

// Cron-Based Recurring Transaction Handler 
// Stores a list of paid rebalancer UUIDs and calls fixReschedule on each of them when the scheduler runs.
// This fixes the reschedule for paid rebalancers if they failed to schedule their next transaction.
access(all) contract FlowCreditMarketSupervisorV1 {

    access(all) event Executed(id: UInt64)
    access(all) event AddedPaidRebalancer(uuid: UInt64)
    access(all) event RemovedPaidRebalancer(uuid: UInt64)

    access(all) resource Supervisor: FlowTransactionScheduler.TransactionHandler {

        // set of paid rebalancer UUIDs (Bool unused)
        access(all) let paidRebalancers: {UInt64: Bool}  

        init() {
            self.paidRebalancers = {}
        }

        access(all) fun addPaidRebalancer(uuid: UInt64) {
            self.paidRebalancers[uuid] = true
            emit AddedPaidRebalancer(uuid: uuid)
        }

        access(all) fun removePaidRebalancer(uuid: UInt64): Bool? {
            let removed = self.paidRebalancers.remove(key: uuid)
            if removed != nil {
                emit RemovedPaidRebalancer(uuid: uuid)
            }
            return removed
        }

        // Scheduler callback: logic which will run every tick.
        // nudge each registered paid rebalancer via fixReschedule, 
        // recovering them if they failed to schedule their next transaction.
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            emit Executed(id: id)
            for rebalancerUUID in self.paidRebalancers.keys {
                FlowCreditMarketRebalancerPaidV1.fixReschedule(uuid: rebalancerUUID)
            }
        }
    }

    access(all) fun createSupervisor(): @Supervisor {
        return <- create Supervisor()
    }
}