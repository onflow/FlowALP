import "FlowCreditMarketRebalancerPaidV1"

transaction(paidRebalancerStoragePath: StoragePath) {
    let paidRebalancerCap: Capability<auth(FlowCreditMarketRebalancerPaidV1.Delete) &FlowCreditMarketRebalancerPaidV1.RebalancerPaid>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.paidRebalancerCap = signer.capabilities.storage.issue<auth(FlowCreditMarketRebalancerPaidV1.Delete) &FlowCreditMarketRebalancerPaidV1.RebalancerPaid>(
            paidRebalancerStoragePath
        )
        assert(self.paidRebalancerCap.check(), message: "Invalid paid rebalancer capability")
    }

    execute {
        self.paidRebalancerCap.borrow()!.delete()
    }
}
