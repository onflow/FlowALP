import "FlowTransactionScheduler"
import "FlowALPRebalancerPaidv1"

// FlowALPSupervisorv1 — Cron-based recovery for paid rebalancers.
//
// Intended for use by the protocol operators only. The Supervisor is a TransactionHandler
// that runs on a schedule (e.g. cron). On each tick it calls fixReschedule(uuid) on every
// registered paid rebalancer UUID. That recovers rebalancers that failed to schedule their
// next run (e.g. temporary lack of funds), so they do not stay stuck. See RebalanceArchitecture.md.
access(all) contract FlowALPSupervisorv1 {

    access(all) event Executed(id: UInt64)
    access(all) event AddedPaidRebalancer(uuid: UInt64)
    access(all) event RemovedPaidRebalancer(uuid: UInt64)

    /// Supervisor holds a set of paid rebalancer UUIDs and, when the scheduler invokes it,
    /// calls FlowALPRebalancerPaidv1.fixReschedule(uuid) for each. The owner must
    /// register the Supervisor with the FlowTransactionScheduler and add paid rebalancer
    /// UUIDs when users create them (and remove when they are deleted).
    access(all) resource Supervisor: FlowTransactionScheduler.TransactionHandler {

        /// Set of paid rebalancer UUIDs to nudge each tick (Bool value unused; map used as set).
        access(all) let paidRebalancers: {UInt64: Bool}

        init() {
            self.paidRebalancers = {}
        }

        /// Register a paid rebalancer by UUID so the Supervisor will call fixReschedule on it each tick.
        /// Call this when a user creates a paid rebalancer (e.g. after createPaidRebalancer).
        access(all) fun addPaidRebalancer(uuid: UInt64) {
            self.paidRebalancers[uuid] = true
            emit AddedPaidRebalancer(uuid: uuid)
        }

        /// Remove a paid rebalancer from the set. Call when the rebalancer is removed (e.g. user
        /// deleted RebalancerPaid) so the Supervisor stops calling fixReschedule for it.
        /// Returns the removed value if the uuid was present, nil otherwise.
        access(all) fun removePaidRebalancer(uuid: UInt64): Bool? {
            let removed = self.paidRebalancers.remove(key: uuid)
            if removed != nil {
                emit RemovedPaidRebalancer(uuid: uuid)
            }
            return removed
        }

        /// Scheduler callback: on each tick, call fixReschedule on every registered paid rebalancer,
        /// recovering any that failed to schedule their next transaction.
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            emit Executed(id: id)
            for rebalancerUUID in self.paidRebalancers.keys {
                FlowALPRebalancerPaidv1.fixReschedule(uuid: rebalancerUUID)
            }
        }
    }

    /// Create and return a new Supervisor resource. The caller should save it, issue a capability
    /// to it (for FlowTransactionScheduler.Execute), and register it with the transaction scheduler.
    access(all) fun createSupervisor(): @Supervisor {
        return <- create Supervisor()
    }
}