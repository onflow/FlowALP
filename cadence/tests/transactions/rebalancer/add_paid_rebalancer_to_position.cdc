import "FlowALPPositionResources"
import "FlowALPRebalancerPaidv1"

transaction(positionStoragePath: StoragePath) {
    prepare(signer: auth(Storage) &Account) {
        let position = signer.storage.borrow<&FlowALPPositionResources.Position>(from: positionStoragePath)!
        FlowALPRebalancerPaidv1.createPaidRebalancer(positionID: position.id)
    }
}
