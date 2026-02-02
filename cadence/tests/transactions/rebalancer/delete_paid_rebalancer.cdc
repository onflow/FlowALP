import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"
import "MockFlowCreditMarketConsumer"
import "FlowCreditMarketRebalancerV1"
import "FlowCreditMarketRebalancerPaidV1"

transaction() {
    let paidRebalancerCap: Capability<&FlowCreditMarketRebalancerPaidV1.RebalancerPaid>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.paidRebalancerCap = signer.capabilities.storage.issue<&FlowCreditMarketRebalancerPaidV1.RebalancerPaid>(
            StoragePath(identifier: "FCM.PaidRebalancer")!
        )
        assert(self.paidRebalancerCap.check(), message: "Invalid paid rebalancer capability")
    }

    execute {
        self.paidRebalancerCap.borrow()!.delete()
    }
}
