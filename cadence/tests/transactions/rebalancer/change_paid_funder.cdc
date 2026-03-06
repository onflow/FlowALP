import "FungibleToken"
import "FungibleTokenConnectors"
import "FlowALPRebalancerv1"
import "FlowALPRebalancerPaidv1"
import "FlowToken"
import "FlowTransactionScheduler"

// Changes the recurring config for a paid rebalancer, using a different account as txFunder.
// `admin` must hold FlowALPRebalancerPaidv1.Admin; `newFunder` provides the new fee vault.
transaction(uuid: UInt64, interval: UInt64) {
    let adminCap: Capability<&FlowALPRebalancerPaidv1.Admin>
    let newFunderVaultCap: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>

    prepare(admin: auth(IssueStorageCapabilityController) &Account, newFunder: auth(IssueStorageCapabilityController) &Account) {
        self.adminCap = admin.capabilities.storage.issue<&FlowALPRebalancerPaidv1.Admin>(
            FlowALPRebalancerPaidv1.adminStoragePath
        )
        assert(self.adminCap.check(), message: "Invalid admin capability")

        self.newFunderVaultCap = newFunder.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            /storage/flowTokenVault
        )
        assert(self.newFunderVaultCap.check(), message: "Invalid new funder vault capability")
    }

    execute {
        let sinkSource = FungibleTokenConnectors.VaultSinkAndSource(
            min: nil, max: nil, vault: self.newFunderVaultCap, uniqueID: nil
        )
        let config = FlowALPRebalancerv1.RecurringConfigImplv1(
            interval: interval,
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 1000,
            estimationMargin: 1.05,
            forceRebalance: false,
            txFunder: sinkSource
        )
        self.adminCap.borrow()!.updateRecurringConfig(uuid: uuid, recurringConfig: config)
    }
}
