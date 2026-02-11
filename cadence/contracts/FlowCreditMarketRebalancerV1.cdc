import "DeFiActions"
import "FlowCreditMarket"
import "FlowToken"
import "FlowTransactionScheduler"
import "FungibleToken"
import "FlowFees"

// FlowCreditMarketRebalancerV1 — Self-custody scheduled rebalancer for Flow Credit Market positions.
//
// Users create and store a Rebalancer resource in their own account. They supply a RecurringConfig
// (interval, priority, executionEffort, estimationMargin, forceRebalance, txnFunder) and a
// capability to a position. After saving the Rebalancer, users must issue a capability to it
// and call setSelfCapability so it can register with the FlowTransactionScheduler. The scheduler
// then invokes executeTransaction on the configured interval; each run rebalances the position
// (using the txnFunder for fees) and schedules the next run. If scheduling the next run fails
// (e.g. insufficient fees), fixReschedule() can be called by anyone—including an off-chain
// supervisor—to retry; it is idempotent. See RebalanceArchitecture.md for an architecture overview.
access(all) contract FlowCreditMarketRebalancerV1 {

    access(all) event Rebalanced(
        uuid: UInt64,
        positionID: UInt64,
        force: Bool,
        scheduledTimestamp: UFix64,
        currentTimestamp: UFix64,
        nextScheduledTimestamp: UFix64,
        scheduledTransactionID: UInt64,
    )
    access(all) event FixedReschedule(
        uuid: UInt64,
        nextScheduledTimestamp: UFix64,
    )
    access(all) event CreatedRebalancer(
        uuid: UInt64,
        positionID: UInt64,
    )
    access(all) event FailedRecurringSchedule(
        uuid: UInt64,
        whileExecuting: UInt64,
        address: Address?,
        error: String,
    )

    /// Configuration for how often and how the rebalancer runs, and which account pays scheduler fees.
    access(all) struct RecurringConfig {
        /// How frequently the rebalance will be executed (in seconds).
        access(all) let interval: UInt64
        access(all) let priority: FlowTransactionScheduler.Priority
        access(all) let executionEffort: UInt64
        /// The margin to multiply with the estimated fees for the scheduled transaction
        /// feePaid = estimate.flowFee * estimationMargin
        access(all) let estimationMargin: UFix64
        /// The force rebalance flag
        access(all) let forceRebalance: Bool
        /// The txnFunder used to fund the rebalance - must provide FLOW and accept FLOW
        access(contract) var txnFunder: {DeFiActions.Sink, DeFiActions.Source}

        init(
            interval: UInt64,
            priority: FlowTransactionScheduler.Priority,
            executionEffort: UInt64,
            estimationMargin: UFix64,
            forceRebalance: Bool,
            txnFunder: {DeFiActions.Sink, DeFiActions.Source}
        ) {
            pre {
                interval > UInt64(0):
                "Invalid interval: \(interval) - must be greater than 0"
                interval < UInt64(UFix64.max) - UInt64(getCurrentBlock().timestamp):
                "Invalid interval: \(interval) - must be less than the maximum interval of \(UInt64(UFix64.max) - UInt64(getCurrentBlock().timestamp))"
                priority != FlowTransactionScheduler.Priority.High:
                "Invalid priority: \(priority.rawValue) - must not be High"
                txnFunder.getSourceType() == Type<@FlowToken.Vault>():
                "Invalid txnFunder: \(txnFunder.getSourceType().identifier) - must provide FLOW but provides \(txnFunder.getSourceType().identifier)"
                txnFunder.getSinkType() == Type<@FlowToken.Vault>():
                "Invalid txnFunder: \(txnFunder.getSinkType().identifier) - must accept FLOW but accepts \(txnFunder.getSinkType().identifier)"
            }
            let schedulerConfig = FlowTransactionScheduler.getConfig()
            let minEffort = schedulerConfig.minimumExecutionEffort
            assert(executionEffort >= minEffort,
                message: "Invalid execution effort: \(executionEffort) - must be greater than or equal to the minimum execution effort of \(minEffort)")
            assert(executionEffort <= schedulerConfig.maximumIndividualEffort,
                message: "Invalid execution effort: \(executionEffort) - must be less than or equal to the maximum individual effort of \(schedulerConfig.maximumIndividualEffort)")

            self.interval = interval
            self.priority = priority
            self.executionEffort = executionEffort
            self.estimationMargin = estimationMargin
            self.forceRebalance = forceRebalance
            self.txnFunder = txnFunder
        }
    }

    /// Rebalancer runs the position's rebalance on a schedule. The owner can setRecurringConfig,
    /// call fixReschedule (or have a supervisor do so) to recover from scheduling failures, or
    /// call cancelAllScheduledTransactions then destroy the resource to stop and rebate fees.
    access(all) resource Rebalancer : FlowTransactionScheduler.TransactionHandler {

        access(all) var lastRebalanceTimestamp: UFix64
        access(all) var nextScheduledRebalanceTimestamp: UFix64?
        access(all) var recurringConfig: RecurringConfig

        access(self) var _selfCapability: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>?
        access(self) var _positionRebalanceCapability: Capability<auth(FlowCreditMarket.ERebalance) &FlowCreditMarket.Position>
        /// Scheduled transaction id -> ScheduledTransaction (used to cancel/refund).
        access(self) var scheduledTransactions: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}

        /// Entitlement required to call setRecurringConfig (owner only for standard rebalancers).
        access(all) entitlement Configure

        access(all) event ResourceDestroyed(uuid: UInt64 = self.uuid)

        init(
            recurringConfig: RecurringConfig,
            positionRebalanceCapability: Capability<auth(FlowCreditMarket.ERebalance) &FlowCreditMarket.Position>
        ) {
            self._selfCapability = nil
            self.lastRebalanceTimestamp = getCurrentBlock().timestamp
            self.recurringConfig = recurringConfig
            self.scheduledTransactions <- {}
            self._positionRebalanceCapability = positionRebalanceCapability
            self.nextScheduledRebalanceTimestamp = nil

            emit CreatedRebalancer(
                uuid: self.uuid,
                positionID: positionRebalanceCapability.borrow()!.id
            )
        }

        /// Enables the setting of a Capability on the Rebalancer, this must be done after the Rebalancer
        /// has been saved to account storage and an authorized Capability has been issued.
        access(account) fun setSelfCapability(_ cap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>) {
            pre {
                cap.check(): "Invalid Rebalancer Capability provided"
            }
            self._selfCapability = cap
        }
        
        /// Intended to be used by the FlowTransactionScheduler to execute the rebalance.
        ///
        /// @param id: The id of the scheduled transaction
        /// @param data: The data that was passed when the transaction was originally scheduled
        ///
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            // we want to panic and not keep spending fees on scheduled transactions if borrow fails
            let positionRebalanceCap = self._positionRebalanceCapability.borrow()!
            positionRebalanceCap.rebalance(force: self.recurringConfig.forceRebalance)
            self.lastRebalanceTimestamp = getCurrentBlock().timestamp
            emit Rebalanced(
                uuid: self.uuid,
                positionID: positionRebalanceCap.id,
                force: self.recurringConfig.forceRebalance,
                scheduledTimestamp: self.nextScheduledRebalanceTimestamp!,
                currentTimestamp: getCurrentBlock().timestamp,
                nextScheduledTimestamp: self.nextExecutionTimestamp(),
                scheduledTransactionID: id,
            )

            let err = self.scheduleNextRebalance()
            if err != nil {
                emit FailedRecurringSchedule(
                    uuid: self.uuid,
                    whileExecuting: id,
                    address: self.owner?.address,
                    error: err!,
                )
            }
            self.removeAllNonScheduledTransactions()
        }
        
        /// Schedules the next execution of the rebalance. This method is written to fail as gracefully as
        /// possible, reporting any failures to schedule the next execution to the calling function as a string to be emitted in an event. 
        /// This allows `executeTransaction` to continue execution even if the next execution cannot be scheduled while still
        /// informing of the failure via `FailedRecurringSchedule` event.
        /// Custom code of the txnFunder is called which can panic the transaction. But this is purely a quality of live improvement, 
        /// making sure the last rebalancing does not get reverted.
        ///
        /// @return String?: The error message, or nil if the next execution was scheduled
        ///
        access(self) fun scheduleNextRebalance(): String? {
            var nextTimestamp = self.nextExecutionTimestamp()
            self.nextScheduledRebalanceTimestamp = nextTimestamp

            let flowFee = self.transactionSchedulerCalculateFee(priority: self.recurringConfig.priority, executionEffort: self.recurringConfig.executionEffort)
            let feeWithMargin = flowFee * self.recurringConfig.estimationMargin
            if self.recurringConfig.txnFunder.minimumAvailable() < feeWithMargin {
                return "INSUFFICIENT_FEES_AVAILABLE"
            }

            let fees <- self.recurringConfig.txnFunder.withdrawAvailable(maxAmount: feeWithMargin) as! @FlowToken.Vault
            if fees.balance < feeWithMargin {
                self.recurringConfig.txnFunder.depositCapacity(from: &fees as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                if fees.balance > 0.0 {
                    panic("can't deposit full amount of fees back to the txnFunder, remaining: \(fees.balance)")
                }
                destroy fees
                return "INSUFFICIENT_FEES_PROVIDED"
            } else {
                // all checks passed - schedule the transaction & capture the scheduled transaction
                let txn <- FlowTransactionScheduler.schedule(
                        handlerCap: self._selfCapability!,
                        data: nil,
                        timestamp: nextTimestamp,
                        priority: self.recurringConfig.priority,
                        executionEffort: self.recurringConfig.executionEffort,
                        fees: <-fees
                    )
                let txnID = txn.id
                self.scheduledTransactions[txnID] <-! txn
                return nil
            }
        }

        /// Calculates the FLOW fee for scheduling a transaction using the official FlowFees calculation.
        /// Will be replaced with FlowTransactionScheduler.calculateFee in the future, once it is available in the emulator.
        access(self) fun transactionSchedulerCalculateFee(priority: FlowTransactionScheduler.Priority, executionEffort: UInt64): UFix64 {
            // Use the official FlowFees calculation
            let baseFee = FlowFees.computeFees(inclusionEffort: 1.0, executionEffort: UFix64(executionEffort)/100_000_000.0)
            // Scale the execution fee by the multiplier for the priority
            let scaledExecutionFee = baseFee * FlowTransactionScheduler.getConfig().priorityFeeMultipliers[priority]!
            // Add inclusion Flow fee for scheduled transactions
            let inclusionFee = 0.00001

            let flowFee = scaledExecutionFee + inclusionFee
            return flowFee
        }

        /// Idempotent, schedules a new transaction if there is no scheduled transaction.
        /// 
        /// This function is designed to be safely callable by any account, including an off-chain supervisor,
        /// to help recover from issues where the next scheduled transaction could not be scheduled.
        access(all) fun fixReschedule() {
            self.removeAllNonScheduledTransactions()
           
            if self.scheduledTransactions.keys.length == 0 {
                let err = self.scheduleNextRebalance()
                if err != nil {
                    emit FailedRecurringSchedule(
                        uuid: self.uuid,
                        whileExecuting: 0,
                        address: self.owner?.address,
                        error: err!,
                    )
                } else {
                    emit FixedReschedule(
                        uuid: self.uuid,
                        nextScheduledTimestamp: self.nextExecutionTimestamp(),
                    )
                }
            }
        }

        access(self) view fun borrowScheduledTransaction(id: UInt64): &FlowTransactionScheduler.ScheduledTransaction? {
            return &self.scheduledTransactions[id]
        }

        /// Returns the next execution timestamp (lastRebalanceTimestamp + interval), clamped to the future.
        access(all) view fun nextExecutionTimestamp(): UFix64 {
            // protect overflow
            if UInt64(UFix64.max) - UInt64(self.lastRebalanceTimestamp) <= UInt64(self.recurringConfig.interval) {
                return UFix64.max
            }
            var nextTimestamp = self.lastRebalanceTimestamp + UFix64(self.recurringConfig.interval)
            let nextPossibleTimestamp = getCurrentBlock().timestamp + 1.0;
            // it must be in the future
            if nextTimestamp < nextPossibleTimestamp {
                nextTimestamp = nextPossibleTimestamp
            }
            return nextTimestamp
        }

        /// Update schedule and fee config. Cancels existing scheduled transactions and schedules the next run with the new config.
        access(Configure) fun setRecurringConfig(_ config: RecurringConfig) {
            self.recurringConfig = config
            self.cancelAllScheduledTransactions()
            let err = self.scheduleNextRebalance()
            if err != nil {
                panic("Failed to schedule next rebalance after setting recurring config: \(err!)")
            }
        }

        /// Cancel all scheduled rebalance transactions and refund fees to the txnFunder.
        access(FlowTransactionScheduler.Cancel) fun cancelAllScheduledTransactions() {
            while self.scheduledTransactions.keys.length > 0 {
                self.cancelScheduledTransaction(id: self.scheduledTransactions.keys[0])
            }
        }

        /// Cancel one scheduled transaction, remove it from the map, and refund its fees to the txnFunder.
        access(FlowTransactionScheduler.Cancel) fun cancelScheduledTransaction(id: UInt64) {
            let txn <- self.scheduledTransactions.remove(key: id)!
            if txn.status() != FlowTransactionScheduler.Status.Scheduled {
                destroy txn
                return
            }
            let refund <- FlowTransactionScheduler.cancel(scheduledTx: <-txn)
            self.recurringConfig.txnFunder.depositCapacity(from: &refund as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            if refund.balance > 0.0 {
                panic("can't deposit full amount of refund back to the txnFunder, remaining: \(refund.balance)")
            }
            destroy refund
        }

        /// Drop any scheduled transactions that are no longer Scheduled (e.g. already executed or cancelled).
        access(self) fun removeAllNonScheduledTransactions() {
            for id in self.scheduledTransactions.keys {
                let txn = self.borrowScheduledTransaction(id: id)!
                if txn.status() != FlowTransactionScheduler.Status.Scheduled {
                    destroy self.scheduledTransactions.remove(key: id)
                }
            }
        }
    }

    /// Create a new Rebalancer. The caller must save it to storage, issue a capability to it,
    /// call setSelfCapability with that capability, then call fixReschedule() to start the schedule.
    access(all) fun createRebalancer(
        recurringConfig: RecurringConfig,
        positionRebalanceCapability: Capability<auth(FlowCreditMarket.ERebalance) &FlowCreditMarket.Position>,
    ): @Rebalancer {
        let rebalancer <- create Rebalancer(
            recurringConfig: recurringConfig, 
            positionRebalanceCapability: positionRebalanceCapability
        )
        return <- rebalancer
    }
}
