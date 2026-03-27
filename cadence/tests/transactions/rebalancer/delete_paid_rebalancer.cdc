import "FlowALPRebalancerPaidv1"

transaction(positionID: UInt64) {
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<&FlowALPRebalancerPaidv1.Admin>(from: FlowALPRebalancerPaidv1.adminStoragePath)!
        admin.removePaidRebalancer(positionID: positionID)
    }
}
