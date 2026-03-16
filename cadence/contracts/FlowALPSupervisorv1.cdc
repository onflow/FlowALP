import "FlowTransactionScheduler"
import "FlowALPRebalancerPaidv1"

// FlowALPSupervisorv1 — Cron-based recovery for paid rebalancers.
//
// Intended for use by the protocol operators only. The Supervisor is a TransactionHandler
// that runs on a schedule (e.g. cron). On each tick it calls fixReschedule(positionID) on every
// registered paid rebalancer position ID. That recovers rebalancers that failed to schedule their
// next run (e.g. temporary lack of funds), so they do not stay stuck. See RebalanceArchitecture.md.
access(all) contract FlowALPSupervisorv1 {

    access(all) event Executed(id: UInt64)
    access(all) event AddedPaidRebalancer(positionID: UInt64)
    access(all) event RemovedPaidRebalancer(positionID: UInt64)

    /// Supervisor holds a set of paid rebalancer position IDs and, when the scheduler invokes it,
    /// calls FlowALPRebalancerPaidv1.fixReschedule(positionID) for each. The owner must
    /// register the Supervisor with the FlowTransactionScheduler and add paid rebalancer
    /// position IDs when users create them (and remove when they are deleted).
    access(all) resource Supervisor: FlowTransactionScheduler.TransactionHandler {

        /// Set of paid rebalancer position IDs to nudge each tick (Bool value unused; map used as set).
        access(all) let paidRebalancers: {UInt64: Bool}

        init() {
            self.paidRebalancers = {}
        }

        /// Register a paid rebalancer by position ID so the Supervisor will call fixReschedule on it each tick.
        /// Call this when a user creates a paid rebalancer (e.g. after createPaidRebalancer).
        access(all) fun addPaidRebalancer(positionID: UInt64) {
            self.paidRebalancers[positionID] = true
            emit AddedPaidRebalancer(positionID: positionID)
        }

        /// Remove a paid rebalancer from the set. Call when the rebalancer is removed (e.g. user
        /// deleted RebalancerPaid) so the Supervisor stops calling fixReschedule for it.
        /// Returns the removed value if the positionID was present, nil otherwise.
        access(all) fun removePaidRebalancer(positionID: UInt64): Bool? {
            let removed = self.paidRebalancers.remove(key: positionID)
            if removed != nil {
                emit RemovedPaidRebalancer(positionID: positionID)
            }
            return removed
        }

        /// Scheduler callback: on each tick, call fixReschedule on every registered paid rebalancer,
        /// recovering any that failed to schedule their next transaction.
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            emit Executed(id: id)
            for positionID in self.paidRebalancers.keys {
                FlowALPRebalancerPaidv1.fixReschedule(positionID: positionID)
            }
        }
    }

    /// Create and return a new Supervisor resource. The caller should save it, issue a capability
    /// to it (for FlowTransactionScheduler.Execute), and register it with the transaction scheduler.
    access(all) fun createSupervisor(): @Supervisor {
        return <- create Supervisor()
    }
}