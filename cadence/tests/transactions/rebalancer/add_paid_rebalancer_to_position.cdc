import "FlowCreditMarket"
import "FlowCreditMarketRebalancerV1"
import "FlowCreditMarketRebalancerPaidV1"

transaction(positionStoragePath: StoragePath, paidRebalancerStoragePath: StoragePath) {
    let signer: auth(Storage, IssueStorageCapabilityController, SaveValue) &Account

    prepare(signer: auth(Storage, IssueStorageCapabilityController, SaveValue) &Account) {
        self.signer = signer
    }

    execute {
        let rebalanceCap = self.signer.capabilities.storage.issue<auth(FlowCreditMarket.ERebalance) &FlowCreditMarket.Position>(
            positionStoragePath
        )
        let paidRebalancer <- FlowCreditMarketRebalancerPaidV1.createPaidRebalancer(
            positionRebalanceCapability: rebalanceCap
        )
        self.signer.storage.save(<-paidRebalancer, to: paidRebalancerStoragePath)
    }
}
