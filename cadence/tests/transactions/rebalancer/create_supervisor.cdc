import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FungibleToken"
import "FlowToken"
import "FlowCron"
import "FlowFees"
import "FlowCreditMarketSupervisorV1"

transaction(
    cronExpression: String,
    cronHandlerStoragePath: StoragePath,
    keeperExecutionEffort: UInt64,
    executorExecutionEffort: UInt64,
    supervisorStoragePath: StoragePath
) {
    let signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue) &Account
    let feeProviderCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue) &Account) {
        self.feeProviderCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
        self.signer = signer
    }

    execute {
        let supervisor <- FlowCreditMarketSupervisorV1.createSupervisor()
        self.signer.storage.save(<-supervisor, to: supervisorStoragePath)
        let wrappedHandlerCap = 
            self.signer.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}
        >(supervisorStoragePath)
        assert(wrappedHandlerCap.check(), message: "Invalid wrapped handler capability")
        self.signer.storage.save(<-FlowTransactionSchedulerUtils.createManager(), to: FlowTransactionSchedulerUtils.managerStoragePath)
        let schedulerManagerCap: Capability<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}> = self.signer.capabilities.storage.issue<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
            FlowTransactionSchedulerUtils.managerStoragePath
        )
        let manager = self.signer.storage.borrow<auth(FlowTransactionSchedulerUtils.Owner) &{FlowTransactionSchedulerUtils.Manager}>(
            from: FlowTransactionSchedulerUtils.managerStoragePath
        ) ?? panic("Cannot borrow manager")
        assert(schedulerManagerCap.check(), message: "Invalid scheduler manager capability")
        let cronHandler <- FlowCron.createCronHandler(
            cronExpression: cronExpression,
            wrappedHandlerCap: wrappedHandlerCap,
            feeProviderCap: self.feeProviderCap,
            schedulerManagerCap: schedulerManagerCap
        )
        self.signer.storage.save(<-cronHandler, to: cronHandlerStoragePath)
        let cronHandlerCap = self.signer.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(cronHandlerStoragePath)
        assert(cronHandlerCap.check(), message: "Invalid cron handler capability")

        // Use the official FlowFees calculation
        let executorBaseFee = FlowFees.computeFees(inclusionEffort: 1.0, executionEffort: 0.0)
        // Scale the execution fee by the multiplier for the priority
        let executorScaledExecutionFee = executorBaseFee * FlowTransactionScheduler.getConfig().priorityFeeMultipliers[FlowTransactionScheduler.Priority.Low]!
        // Add inclusion Flow fee for scheduled transactions
        let inclusionFee = 0.00001

        let executorFlowFee = executorScaledExecutionFee + inclusionFee

        let keeperBaseFee = FlowFees.computeFees(inclusionEffort: 1.0, executionEffort: 0.0)
        let keeperScaledExecutionFee = keeperBaseFee * FlowTransactionScheduler.getConfig().priorityFeeMultipliers[FlowCron.keeperPriority]!
        let keeperFlowFee = keeperScaledExecutionFee + inclusionFee

        let totalFee = executorFlowFee + keeperFlowFee

        // Borrow fee vault and check balance
        let feeVault = self.signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Flow token vault not found")

        if feeVault.balance < totalFee {
            panic("Insufficient funds: required ".concat(totalFee.toString()).concat(" FLOW (executor: ").concat(executorFlowFee.toString()).concat(", keeper: ").concat(keeperFlowFee.toString()).concat("), available ").concat(feeVault.balance.toString()))
        }

        // Withdraw fees for BOTH transactions
        let executorFees <- feeVault.withdraw(amount: executorFlowFee) as! @FlowToken.Vault
        let keeperFees <- feeVault.withdraw(amount: keeperFlowFee) as! @FlowToken.Vault

        let executorContext = FlowCron.CronContext(
            executionMode: FlowCron.ExecutionMode.Executor,
            executorPriority: FlowTransactionScheduler.Priority.Low,
            executorExecutionEffort: executorExecutionEffort,
            keeperExecutionEffort: keeperExecutionEffort,
            wrappedData: nil
        )

        let executorTxID = manager.schedule(
            handlerCap: cronHandlerCap,
            data: executorContext,
            timestamp: UFix64(getCurrentBlock().timestamp + 1.0),
            priority: FlowTransactionScheduler.Priority.Low,
            executionEffort: executorExecutionEffort,
            fees: <-executorFees
        )


        let keeperContext = FlowCron.CronContext(
            executionMode: FlowCron.ExecutionMode.Keeper,
            executorPriority: FlowTransactionScheduler.Priority.Low,
            executorExecutionEffort: executorExecutionEffort,
            keeperExecutionEffort: keeperExecutionEffort,
            wrappedData: nil
        )

        // Schedule KEEPER transaction (1 second after executor to prevent race conditions)
        let keeperTxID = manager.schedule(
            handlerCap: cronHandlerCap,
            data: keeperContext,
            timestamp: UFix64(getCurrentBlock().timestamp + 2.0),
            priority: FlowCron.keeperPriority,
            executionEffort: keeperExecutionEffort,
            fees: <-keeperFees
        )
    }
}