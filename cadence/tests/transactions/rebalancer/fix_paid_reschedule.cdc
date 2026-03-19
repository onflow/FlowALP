import "FlowALPRebalancerPaidv1"

transaction(positionID: UInt64?, paidRebalancerStoragePath: StoragePath) {
    let positionIDToFix: UInt64

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        if positionID != nil {
            self.positionIDToFix = positionID!
        } else {
            let paidRebalancerCap = signer.capabilities.storage.issue<&FlowALPRebalancerPaidv1.RebalancerPaid>(
                paidRebalancerStoragePath
            )
            assert(paidRebalancerCap.check(), message: "Invalid paid rebalancer capability")
            self.positionIDToFix = paidRebalancerCap.borrow()!.positionID
        }
    }

    execute {
        FlowALPRebalancerPaidv1.fixReschedule(positionID: self.positionIDToFix)
    }
}
