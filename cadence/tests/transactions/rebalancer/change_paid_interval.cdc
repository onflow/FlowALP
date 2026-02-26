import "FungibleToken"
import "FungibleTokenConnectors"
import "FlowALPRebalancerv1"
import "FlowALPRebalancerPaidv1"
import "FlowToken"
import "FlowTransactionScheduler"

transaction(uuid: UInt64, interval: UInt64) {
    let adminPaidRebalancerCap: Capability<&FlowALPRebalancerPaidv1.Admin>
    let vaultCapability: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.adminPaidRebalancerCap = signer.capabilities.storage.issue<&FlowALPRebalancerPaidv1.Admin>(
            FlowALPRebalancerPaidv1.adminStoragePath
        )
        assert(self.adminPaidRebalancerCap.check(), message: "Invalid admin paid rebalancer capability")
        self.vaultCapability = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
        assert(self.vaultCapability.check(), message: "Invalid vault capability")
    }

    execute {
        let sinkSource = FungibleTokenConnectors.VaultSinkAndSource(min: nil, max: nil, vault: self.vaultCapability, uniqueID: nil)

        let borrowedRebalancer = self.adminPaidRebalancerCap.borrow()!.borrowAuthorizedRebalancer(uuid: uuid)!
        let config = FlowALPRebalancerv1.RecurringConfigImplv1(
            interval: interval,
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 1000,
            estimationMargin: 1.05,
            forceRebalance: false,
            txFunder: sinkSource
        )
        borrowedRebalancer.setRecurringConfig(config)
    }
}
