import "FlowToken"
import "FungibleToken"
import "FlowALPRebalancerPaidv1"
import "FlowALPModels"
import "FlowALPv0"
import "FlowTransactionScheduler"
import "FungibleTokenConnectors"

transaction(paidRebalancerAdminStoragePath: StoragePath) {
    let admin: &FlowALPRebalancerPaidv1.Admin
    let vaultCapability: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>

    prepare(signer: auth(Capabilities, BorrowValue, IssueStorageCapabilityController) &Account) {
        self.admin = signer.storage.borrow<&FlowALPRebalancerPaidv1.Admin>(from: paidRebalancerAdminStoragePath)!
        self.vaultCapability = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)

        let poolCap = signer.capabilities.storage.issue<auth(FlowALPModels.ERebalance) &{FlowALPModels.PositionPool}>(FlowALPv0.PoolStoragePath)
        self.admin.setPoolCap(poolCap)
    }

    execute {
        let sinkSource = FungibleTokenConnectors.VaultSinkAndSource(min: nil, max: nil, vault: self.vaultCapability, uniqueID: nil)
        assert(sinkSource.minimumAvailable() > 0.0, message: "Insufficient funds available")

        let config = FlowALPRebalancerPaidv1.RecurringConfig(
            interval: 100,
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 1000,
            estimationMargin: 1.05,
            forceRebalance: false,
            txFunder: sinkSource
        )
        self.admin.updateDefaultRecurringConfig(config)
    }
}
