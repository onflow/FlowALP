import "FlowALPv0"
import "FlowALPModels"
import "FlowTransactionScheduler"
import "FlowToken"
import "FungibleToken"
import "FlowFees"
import "DeFiActions"

// FlowALPRebalancerPaidv1 — Managed rebalancer service for Flow ALP positions.
//
// This contract hosts scheduled rebalancers on behalf of users. Anyone may call createPaidRebalancer
// (permissionless): pass a positionID and receive a lightweight RebalancerPaid resource. The contract
// rebalances using a contract-level pool capability (set by Admin), so no per-position capability is
// required from the caller. The admin's txFunder is used to pay for rebalance transactions. We rely on
// 2 things to limit how funds can be spent indirectly by creating rebalancers in this way:
// 1. This contract enforces that only one rebalancer can be created per position.
// 2. FlowALP enforces a minimum economic value per position.
// Users can fixReschedule (via their RebalancerPaid) or delete RebalancerPaid to stop. Admins control
// the default config and can update or remove individual paid rebalancers. See RebalanceArchitecture.md.
access(all) contract FlowALPRebalancerPaidv1 {

    access(all) event CreatedRebalancerPaid(positionID: UInt64)
    access(all) event RemovedRebalancerPaid(positionID: UInt64)
    access(all) event Rebalanced(
        positionID: UInt64,
        force: Bool,
        currentTimestamp: UFix64,
        nextScheduledTimestamp: UFix64?,
        scheduledTransactionID: UInt64,
    )
    access(all) event FailedRecurringSchedule(
        positionID: UInt64,
        address: Address?,
        error: String,
    )
    access(all) event FixedReschedule(
        positionID: UInt64,
        nextScheduledTimestamp: UFix64,
    )
    access(all) event UpdatedDefaultRecurringConfig(
        interval: UInt64,
        priority: UInt8,
        executionEffort: UInt64,
        estimationMargin: UFix64,
        forceRebalance: Bool,
    )

    /// Configuration for how often and how the rebalancer runs, and which account pays scheduler fees.
    access(all) struct RecurringConfig {
        /// Period of rebalance transactions, in seconds.
        access(all) let interval: UInt64
        access(all) let priority: FlowTransactionScheduler.Priority
        access(all) let executionEffort: UInt64
        /// feePaid = estimate.flowFee * estimationMargin
        /// For example, for a 5% margin, set estimationMargin=1.05
        access(all) let estimationMargin: UFix64
        /// Whether to force rebalance even when the position is within its configured min/max health bounds.
        access(all) let forceRebalance: Bool
        /// Who pays for rebalance transactions. Must provide and accept FLOW.
        access(contract) var txFunder: {DeFiActions.Sink, DeFiActions.Source}

        init(
            interval: UInt64,
            priority: FlowTransactionScheduler.Priority,
            executionEffort: UInt64,
            estimationMargin: UFix64,
            forceRebalance: Bool,
            txFunder: {DeFiActions.Sink, DeFiActions.Source}
        ) {
            pre {
                interval > 0:
                    "Invalid interval: \(interval) - must be greater than 0"
                UFix64(interval) < UFix64.max - getCurrentBlock().timestamp:
                    "Invalid interval: \(interval) - must be less than the maximum interval"
                priority != FlowTransactionScheduler.Priority.High:
                    "Invalid priority: \(priority.rawValue) - must not be High"
                txFunder.getSourceType() == Type<@FlowToken.Vault>():
                    "Invalid txFunder: must provide FLOW"
                txFunder.getSinkType() == Type<@FlowToken.Vault>():
                    "Invalid txFunder: must accept FLOW"
            }
            let schedulerConfig = FlowTransactionScheduler.getConfig()
            assert(executionEffort >= schedulerConfig.minimumExecutionEffort,
                message: "Invalid execution effort: \(executionEffort) - must be >= minimum \(schedulerConfig.minimumExecutionEffort)")
            assert(executionEffort <= schedulerConfig.maximumIndividualEffort,
                message: "Invalid execution effort: \(executionEffort) - must be <= maximum \(schedulerConfig.maximumIndividualEffort)")

            self.interval = interval
            self.priority = priority
            self.executionEffort = executionEffort
            self.estimationMargin = estimationMargin
            self.forceRebalance = forceRebalance
            self.txFunder = txFunder
        }
    }

    /// Default RecurringConfig for all newly created paid rebalancers. Must be set by Admin before
    /// createPaidRebalancer is used. Includes txFunder, which pays for scheduled rebalance transactions.
    access(all) var defaultRecurringConfig: RecurringConfig?
    access(all) var adminStoragePath: StoragePath
    /// Pool capability used to rebalance positions by ID. Must be set by Admin before createPaidRebalancer is used.
    access(self) var poolCap: Capability<auth(FlowALPModels.ERebalance) &{FlowALPModels.PositionPool}>?

    /// PositionRebalancer — per-position scheduled rebalancer stored in this contract's account.
    /// Implements TransactionHandler so FlowTransactionScheduler can invoke rebalances.
    access(all) resource PositionRebalancer: FlowTransactionScheduler.TransactionHandler {

        access(all) let positionID: UInt64
        access(all) var lastRebalanceTimestamp: UFix64

        /// A capability referencing this PositionRebalancer, set by the contract when the PositionRebalancer is created (and stored).
        /// This is necessary because in order to schedule the next transaction, we need to pass a persistent reference (capability) to FlowTransactionScheduler.
        access(self) var selfCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>?
        access(self) var scheduledTransactions: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}

        access(all) entitlement Configure

        access(all) event ResourceDestroyed(positionID: UInt64 = self.positionID)

        init(positionID: UInt64) {
            self.positionID = positionID
            self.lastRebalanceTimestamp = getCurrentBlock().timestamp
            self.selfCap = nil
            self.scheduledTransactions <- {}
        }

        access(account) fun setSelfCapability(_ cap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>) {
            pre { cap.check(): "Invalid PositionRebalancer capability" }
            self.selfCap = cap
        }

        /// Invoked by FlowTransactionScheduler to execute each requested scheduled transaction.
        /// @param id: the scheduled transaction ID
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let pool = FlowALPRebalancerPaidv1.poolCap!.borrow()!
            let config = FlowALPRebalancerPaidv1.defaultRecurringConfig!
            pool.rebalancePosition(pid: self.positionID, force: config.forceRebalance)
            self.lastRebalanceTimestamp = getCurrentBlock().timestamp
            let nextScheduledTimestamp = self.scheduleNext()
            emit Rebalanced(
                positionID: self.positionID,
                force: config.forceRebalance,
                currentTimestamp: getCurrentBlock().timestamp,
                nextScheduledTimestamp: nextScheduledTimestamp,
                scheduledTransactionID: id,
            )
            self.removeAllNonScheduledTransactions()
        }

        /// Idempotent: schedules the next run if none is currently scheduled.
        access(all) fun fixReschedule() {
            self.removeAllNonScheduledTransactions()
            if self.scheduledTransactions.keys.length == 0 {
                if let nextTimestamp = self.scheduleNext() {
                    emit FixedReschedule(
                        positionID: self.positionID,
                        nextScheduledTimestamp: nextTimestamp,
                    )
                }
            }
        }

        access(FlowTransactionScheduler.Cancel) fun cancelAllScheduledTransactions() {
            while self.scheduledTransactions.keys.length > 0 {
                self.cancelScheduledTransaction(id: self.scheduledTransactions.keys[0])
            }
        }

        access(FlowTransactionScheduler.Cancel) fun cancelScheduledTransaction(id: UInt64) {
            let tx <- self.scheduledTransactions.remove(key: id)!
            if tx.status() != FlowTransactionScheduler.Status.Scheduled {
                destroy tx
                return
            }
            let refund <- FlowTransactionScheduler.cancel(scheduledTx: <-tx)
            FlowALPRebalancerPaidv1.defaultRecurringConfig!.txFunder.depositCapacity(from: &refund as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            if refund.balance > 0.0 {
                panic("can't deposit full refund back to txFunder, remaining: \(refund.balance)")
            }
            destroy refund
        }

        access(all) view fun nextExecutionTimestamp(): UFix64 {
            let config = FlowALPRebalancerPaidv1.defaultRecurringConfig!
            if UInt64(UFix64.max) - UInt64(self.lastRebalanceTimestamp) <= config.interval {
                return UFix64.max
            }
            var nextTimestamp = self.lastRebalanceTimestamp + UFix64(config.interval)
            let nextPossible = getCurrentBlock().timestamp + 1.0
            if nextTimestamp < nextPossible {
                nextTimestamp = nextPossible
            }
            return nextTimestamp
        }

        access(self) fun scheduleNext(): UFix64? {
            let config = FlowALPRebalancerPaidv1.defaultRecurringConfig!
            let nextTimestamp = self.nextExecutionTimestamp()
            let flowFee = self.calculateFee(priority: config.priority, executionEffort: config.executionEffort)
            let feeWithMargin = flowFee * config.estimationMargin
            let minimumAvailable = config.txFunder.minimumAvailable()
            if minimumAvailable < feeWithMargin {
                emit FailedRecurringSchedule(
                    positionID: self.positionID,
                    address: self.owner?.address,
                    error: "insufficient fees available, expected: \(feeWithMargin) but available: \(minimumAvailable)",
                )
                return nil
            }
            let fees <- config.txFunder.withdrawAvailable(maxAmount: feeWithMargin) as! @FlowToken.Vault
            if fees.balance != feeWithMargin {
                panic("invalid fees balance: \(fees.balance) - expected: \(feeWithMargin)")
            }
            let tx <- FlowTransactionScheduler.schedule(
                handlerCap: self.selfCap!,
                data: nil,
                timestamp: nextTimestamp,
                priority: config.priority,
                executionEffort: config.executionEffort,
                fees: <-fees
            )
            self.scheduledTransactions[tx.id] <-! tx
            return nextTimestamp
        }

        access(self) fun calculateFee(priority: FlowTransactionScheduler.Priority, executionEffort: UInt64): UFix64 {
            let baseFee = FlowFees.computeFees(inclusionEffort: 1.0, executionEffort: UFix64(executionEffort)/100_000_000.0)
            let scaledExecutionFee = baseFee * FlowTransactionScheduler.getConfig().priorityFeeMultipliers[priority]!
            let inclusionFee = 0.00001
            return scaledExecutionFee + inclusionFee
        }

        access(self) fun removeAllNonScheduledTransactions() {
            for id in self.scheduledTransactions.keys {
                let tx = (&self.scheduledTransactions[id] as &FlowTransactionScheduler.ScheduledTransaction?)!
                if tx.status() != FlowTransactionScheduler.Status.Scheduled {
                    destroy self.scheduledTransactions.remove(key: id)
                }
            }
        }
    }

    /// Create a paid rebalancer for the given position. Permissionless: anyone may call this.
    /// Uses defaultRecurringConfig and the contract's pool capability (both must be set by Admin).
    /// Returns a RebalancerPaid resource; the underlying PositionRebalancer is stored in this contract
    /// and the first run is scheduled.
    access(all) fun createPaidRebalancer(positionID: UInt64) {
        let pool = self.poolCap!.borrow()!
        assert(pool.positionExists(pid: positionID), message: "Invalid position ID \(positionID) - position does not exist")
        let rebalancer <- create PositionRebalancer(positionID: positionID)
        // will panic if the rebalancer already exists
        self.storeRebalancer(rebalancer: <-rebalancer, positionID: positionID)
        self.setSelfCapability(positionID: positionID).fixReschedule()
        emit CreatedRebalancerPaid(positionID: positionID)
    }

    /// Admin resource: controls default config, pool capability, and individual rebalancers.
    access(all) resource Admin {

        /// Set the pool capability used to rebalance positions. Must be called before createPaidRebalancer.
        access(all) fun setPoolCap(_ cap: Capability<auth(FlowALPModels.ERebalance) &{FlowALPModels.PositionPool}>) {
            pre { cap.check(): "Invalid pool capability" }
            FlowALPRebalancerPaidv1.poolCap = cap
        }

        /// Set the default RecurringConfig applied to all newly created paid rebalancers.
        access(all) fun updateDefaultRecurringConfig(_ config: RecurringConfig) {
            FlowALPRebalancerPaidv1.defaultRecurringConfig = config
            emit UpdatedDefaultRecurringConfig(
                interval: config.interval,
                priority: config.priority.rawValue,
                executionEffort: config.executionEffort,
                estimationMargin: config.estimationMargin,
                forceRebalance: config.forceRebalance,
            )
        }

        /// Borrow a rebalancer with Configure entitlement to call setRecurringConfig.
        access(all) fun borrowAuthorizedRebalancer(positionID: UInt64): auth(PositionRebalancer.Configure) &PositionRebalancer? {
            return FlowALPRebalancerPaidv1.borrowRebalancer(positionID: positionID)
        }

        /// Remove a paid rebalancer: cancel scheduled transactions (refund to txFunder) and destroy it.
        access(all) fun removePaidRebalancer(positionID: UInt64) {
            FlowALPRebalancerPaidv1.removePaidRebalancer(positionID: positionID)
            emit RemovedRebalancerPaid(positionID: positionID)
        }
    }

    access(all) entitlement Delete

    /// Idempotent: if the rebalancer exists and has no scheduled run, schedule the next one.
    /// Returns true if the rebalancer was found, false if it no longer exists (caller can prune stale refs).
    access(all) fun fixReschedule(positionID: UInt64): Bool {
        if let rebalancer = FlowALPRebalancerPaidv1.borrowRebalancer(positionID: positionID) {
            rebalancer.fixReschedule()
            return true
        }
        return false
    }

    /// Suggested storage path for a user's RebalancerPaid for the given position.
    access(all) view fun getPaidRebalancerPath(positionID: UInt64): StoragePath {
        return StoragePath(identifier: "FlowALP.RebalancerPaidv1_\(self.account.address)_\(positionID)")!
    }

    access(self) fun borrowRebalancer(positionID: UInt64): auth(PositionRebalancer.Configure) &PositionRebalancer? {
        return self.account.storage.borrow<auth(PositionRebalancer.Configure) &PositionRebalancer>(from: self.getPath(positionID: positionID))
    }

    access(self) fun removePaidRebalancer(positionID: UInt64) {
        let rebalancer <- self.account.storage.load<@PositionRebalancer>(from: self.getPath(positionID: positionID))
        rebalancer?.cancelAllScheduledTransactions()
        destroy <- rebalancer
    }

    access(self) fun storeRebalancer(rebalancer: @PositionRebalancer, positionID: UInt64) {
        let path = self.getPath(positionID: positionID)
        if self.account.storage.borrow<&PositionRebalancer>(from: path) != nil {
            panic("rebalancer already exists for positionID \(positionID)")
        }
        self.account.storage.save(<-rebalancer, to: path)
    }

    access(self) fun setSelfCapability(positionID: UInt64): auth(PositionRebalancer.Configure) &PositionRebalancer {
        let selfCap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(self.getPath(positionID: positionID))
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
        self.poolCap = nil
        self.account.storage.save(<- create Admin(), to: self.adminStoragePath)
    }
}
