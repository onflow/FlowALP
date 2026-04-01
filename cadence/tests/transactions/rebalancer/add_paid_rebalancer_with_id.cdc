import "FlowALPRebalancerPaidv1"

transaction(positionID: UInt64) {
    prepare(signer: auth(Storage) &Account) {
        FlowALPRebalancerPaidv1.createPaidRebalancer(positionID: positionID)
    }
}
