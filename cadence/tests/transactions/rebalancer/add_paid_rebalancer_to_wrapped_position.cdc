import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"
import "MockFlowCreditMarketConsumer"
import "FlowCreditMarketRebalancerV1"
import "FlowCreditMarketRebalancerPaidV1"

transaction() {
    let signer: auth(Storage, IssueStorageCapabilityController, SaveValue) &Account

    prepare(signer: auth(Storage, IssueStorageCapabilityController, SaveValue) &Account) {
        self.signer = signer
    }

    execute {
        let rebalanceCap = self.signer.capabilities.storage.issue<auth(FlowCreditMarket.Rebalance) &{FlowCreditMarketRebalancerV1.Rebalancable}>(
            MockFlowCreditMarketConsumer.WrapperStoragePath
        )
        let paidRebalancer <- FlowCreditMarketRebalancerPaidV1.createPaidRebalancer(
            positionRebalanceCapability: rebalanceCap
        )
        self.signer.storage.save(<-paidRebalancer, to: StoragePath(identifier: "FCM.PaidRebalancer")!)
    }
}
