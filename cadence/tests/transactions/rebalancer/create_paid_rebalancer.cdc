import "MockOracle"
import "FlowToken"
import "FungibleToken"
import "FlowCreditMarketRebalancerPaidV1"
import "FlowCreditMarketRebalancerV1"
import "FlowTransactionScheduler"
import "SimpleSinkSource"

transaction() {
    // let signer: auth(Capabilities, BorrowValue, IssueStorageCapabilityController) &Account
    let admin: &FlowCreditMarketRebalancerPaidV1.Admin
    let vaultCapability: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>
    
    prepare(signer: auth(Capabilities, BorrowValue, IssueStorageCapabilityController) &Account) {
        self.admin = signer.storage.borrow<&FlowCreditMarketRebalancerPaidV1.Admin>(from: /storage/flowCreditMarketRebalancerPaidV1Admin)!
        self.vaultCapability = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
    }

    execute {
        let sinkSource = SimpleSinkSource.SinkSource(vault: self.vaultCapability)
        assert(sinkSource.minimumAvailable() > 0.0, message: "Insufficient funds available")

        let config = FlowCreditMarketRebalancerV1.RecurringConfig(
            interval: 100,
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 1000,
            estimationMargin: 1.05,
            forceRebalance: false,
            txnFunder: sinkSource
        )
        self.admin.updateDefaultRecurringConfig(recurringConfig: config)
    }
}
