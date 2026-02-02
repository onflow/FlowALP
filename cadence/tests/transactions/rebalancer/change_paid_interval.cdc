import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"
import "MockFlowCreditMarketConsumer"
import "FlowCreditMarketRebalancerV1"
import "FlowCreditMarketRebalancerPaidV1"
import "SimpleSinkSource"
import "FlowToken"
import "FlowTransactionScheduler"

transaction(uuid: UInt64, interval: UInt64) {
    let adminPaidRebalancerCap: Capability<&FlowCreditMarketRebalancerPaidV1.Admin>
    let vaultCapability: Capability<auth(FungibleToken.Withdraw) &FlowToken.Vault>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.adminPaidRebalancerCap = signer.capabilities.storage.issue<&FlowCreditMarketRebalancerPaidV1.Admin>(
            FlowCreditMarketRebalancerPaidV1.storageAdminPath
        )
        assert(self.adminPaidRebalancerCap.check(), message: "Invalid admin paid rebalancer capability")
        self.vaultCapability = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)
        assert(self.vaultCapability.check(), message: "Invalid vault capability")
    }

    execute {
        let sinkSource = SimpleSinkSource.SinkSource(vault: self.vaultCapability)
        
        let borrowedRebalancer = self.adminPaidRebalancerCap.borrow()!.borrowRebalancer(uuid: uuid)!
        let config = FlowCreditMarketRebalancerV1.RecurringConfig(
            interval: interval,
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 1000,
            estimationMargin: 1.05,
            forceRebalance: false,
            txnFunder: sinkSource
        )
        borrowedRebalancer.setRecurringConfig(config)
    }
}
