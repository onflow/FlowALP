import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"
import "FlowALPRebalancerv1"
import "FlowALPRebalancerPaidv1"

transaction(positionStoragePath: StoragePath, paidRebalancerStoragePath: StoragePath) {
    let signer: auth(Storage, IssueStorageCapabilityController, SaveValue) &Account

    prepare(signer: auth(Storage, IssueStorageCapabilityController, SaveValue) &Account) {
        self.signer = signer
    }

    execute {
        let rebalanceCap = self.signer.capabilities.storage.issue<auth(FlowALPModels.ERebalance) &FlowALPPositionResources.Position>(
            positionStoragePath
        )
        let paidRebalancer <- FlowALPRebalancerPaidv1.createPaidRebalancer(
            positionRebalanceCapability: rebalanceCap
        )
        self.signer.storage.save(<-paidRebalancer, to: paidRebalancerStoragePath)
    }
}
