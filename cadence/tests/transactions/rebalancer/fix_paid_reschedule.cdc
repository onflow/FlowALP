import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"
import "MockFlowCreditMarketConsumer"
import "FlowCreditMarketRebalancerV1"
import "FlowCreditMarketRebalancerPaidV1"

transaction(uuid: UInt64?) {
    let rebalancerUUID: UInt64
    // let paidRebalancerCap: Capability<&FlowCreditMarketRebalancerPaidV1.RebalancerPaid>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        if uuid != nil {
            self.rebalancerUUID = uuid!
        } else {
            let paidRebalancerCap = signer.capabilities.storage.issue<&FlowCreditMarketRebalancerPaidV1.RebalancerPaid>(
                StoragePath(identifier: "FCM.PaidRebalancer")!
            )
            assert(paidRebalancerCap.check(), message: "Invalid paid rebalancer capability")
            self.rebalancerUUID = paidRebalancerCap.borrow()!.rebalancerUUID
        }
    }

    execute {
        FlowCreditMarketRebalancerPaidV1.fixReschedule(uuid: self.rebalancerUUID)
    }
}
