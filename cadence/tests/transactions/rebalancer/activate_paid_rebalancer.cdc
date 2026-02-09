import "FlowCreditMarketRebalancerPaidV1"

transaction(uuid: UInt64) {
    let adminPaidRebalancerCap: Capability<&FlowCreditMarketRebalancerPaidV1.Admin>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.adminPaidRebalancerCap = signer.capabilities.storage.issue<&FlowCreditMarketRebalancerPaidV1.Admin>(
            FlowCreditMarketRebalancerPaidV1.storageAdminPath
        )
        assert(self.adminPaidRebalancerCap.check(), message: "Invalid admin paid rebalancer capability")
    }

    execute {
        self.adminPaidRebalancerCap.borrow()!.activateRebalancer(uuid: uuid)
    }
}
