import "FlowALPRebalancerPaidv1"

transaction(positionID: UInt64) {
    execute {
        FlowALPRebalancerPaidv1.fixReschedule(positionID: positionID)
    }
}
