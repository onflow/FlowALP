import "FlowALPRebalancerPaidv1"

transaction(uuid: UInt64?, paidRebalancerStoragePath: StoragePath) {
    let rebalancerUUID: UInt64

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        if uuid != nil {
            self.rebalancerUUID = uuid!
        } else {
            let paidRebalancerCap = signer.capabilities.storage.issue<&FlowALPRebalancerPaidv1.RebalancerPaid>(
                paidRebalancerStoragePath
            )
            assert(paidRebalancerCap.check(), message: "Invalid paid rebalancer capability")
            self.rebalancerUUID = paidRebalancerCap.borrow()!.rebalancerUUID
        }
    }

    execute {
        FlowALPRebalancerPaidv1.fixReschedule(uuid: self.rebalancerUUID)
    }
}
