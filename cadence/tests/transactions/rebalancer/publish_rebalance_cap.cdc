import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"
import "MockFlowCreditMarketConsumer"
import "FlowCreditMarketRebalancerV1"
import "FlowCreditMarketRebalancerPaidV1"

transaction(rebalanceCapName: String, grantee: Address) {
    let signer: auth(Storage, IssueStorageCapabilityController, SaveValue, Inbox) &Account

    prepare(signer: auth(Storage, IssueStorageCapabilityController, SaveValue, Inbox) &Account) {
        self.signer = signer
    }

    execute {
        let rebalanceCap = self.signer.capabilities.storage.issue<auth(FlowCreditMarket.ERebalance) &{FlowCreditMarketRebalancerV1.Rebalancable}>(
            MockFlowCreditMarketConsumer.WrapperStoragePath
        )
        self.signer.inbox.publish(rebalanceCap, name: rebalanceCapName, recipient: grantee)
    }
}
