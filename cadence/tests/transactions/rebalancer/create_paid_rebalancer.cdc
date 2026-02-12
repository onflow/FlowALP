import "FlowToken"
import "FungibleToken"
import "FlowALPRebalancerPaidv1"
import "FlowALPRebalancerv1"
import "FlowTransactionScheduler"
import "FungibleTokenConnectors"

transaction(paidRebalancerAdminStoragePath: StoragePath) {
    // let signer: auth(Capabilities, BorrowValue, IssueStorageCapabilityController) &Account
    let admin: &FlowALPRebalancerPaidv1.Admin
    let vaultCapability: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>

    prepare(signer: auth(Capabilities, BorrowValue, IssueStorageCapabilityController) &Account) {
        self.admin = signer.storage.borrow<&FlowALPRebalancerPaidv1.Admin>(from: paidRebalancerAdminStoragePath)!
        self.vaultCapability = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
    }

    execute {
        let sinkSource = FungibleTokenConnectors.VaultSinkAndSource(min: nil, max: nil, vault: self.vaultCapability, uniqueID: nil)
        assert(sinkSource.minimumAvailable() > 0.0, message: "Insufficient funds available")

        let config = FlowALPRebalancerv1.RecurringConfig(
            interval: 100,
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 1000,
            estimationMargin: 1.05,
            forceRebalance: false,
            txFunder: sinkSource
        )
        self.admin.updateDefaultRecurringConfig(recurringConfig: config)
    }
}
